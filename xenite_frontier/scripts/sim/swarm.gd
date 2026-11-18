class_name Swarm
extends Node3D
## Simulates every alien in one tight pass per strain:
##  1. sample flow-field direction for the alien's cell
##  2. add crowd separation from a coarse density grid (previous frame) -
##     O(1) per alien, no neighbour queries
##  3. steer, integrate, slide along blocked cells
##  4. splat into next frame's density grid and write the MultiMesh buffer
## Cost is O(aliens) with a small constant and no allocations.

var map: OutpostMap
var field: FlowField
var pools: Array[AlienPool] = []
var rng := RandomNumberGenerator.new()
var paused := false

# density grid (finer than nav grid)
var _dens := PackedInt32Array()
var _dens_next := PackedInt32Array()
var _dw := 0
var _dh := 0
var _dscale := 2.0

var separation := 2.2
var spread := 2.5
var max_spawn_per_frame := 600

var threaded := true
const CHUNK := 1024

var sim_usec := 0
var upload_usec := 0
var reached_core := 0
var _frame := 0
var _chunk_pool := PackedInt32Array()
var _chunk_start := PackedInt32Array()
var _chunk_reached := PackedInt32Array()
var _f_dt := 0.0
var _f_dirx: PackedFloat32Array
var _f_dirz: PackedFloat32Array
var _f_dist: PackedInt32Array
var _f_blk: PackedByteArray
var _f_dens: PackedInt32Array
var _f_dnext: PackedInt32Array
var _weights := PackedFloat32Array()
var _weight_total := 0.0


func setup(m: OutpostMap, f: FlowField, defs: Array) -> void:
	map = m
	field = f
	var cfg := GameConfig.section("swarm")
	separation = cfg.get("separation", separation)
	spread = cfg.get("intra_cell_spread", spread)
	max_spawn_per_frame = int(cfg.get("max_spawn_per_frame", max_spawn_per_frame))
	threaded = bool(cfg.get("threaded", true))
	_dscale = 1.0 / float(cfg.get("density_cell_size", 0.5))
	_dw = int(map.w * _dscale)
	_dh = int(map.h * _dscale)
	_dens.resize(_dw * _dh)
	_dens_next.resize(_dw * _dh)
	_dens.fill(0)

	var mat := ShaderMaterial.new()
	mat.shader = preload("res://scripts/render/alien.gdshader")
	for i in defs.size():
		var pool := AlienPool.new(i, defs[i], AlienMeshes.build(defs[i].id), mat)
		pools.append(pool)
		add_child(pool.instance)
		_weights.append(float(defs[i].get("spawn_weight", 1)))
		_weight_total += _weights[i]


func total() -> int:
	var t := 0
	for p in pools:
		t += p.count
	return t


func _random_type() -> int:
	var r := rng.randf() * _weight_total
	for i in _weights.size():
		r -= _weights[i]
		if r <= 0.0:
			return i
	return 0


func _spawn_point() -> Vector2:
	var cells := map.spawn_cells
	# only spawn where the field can reach the core
	for attempt in 8:
		var c := cells[rng.randi() % cells.size()]
		if field.dist[c] < FlowField.UNREACHABLE:
			return Vector2(map.origin.x + (c % map.w) + rng.randf(), map.origin.y + (c / map.w) + rng.randf())
	var c0 := cells[rng.randi() % cells.size()]
	return Vector2(map.origin.x + (c0 % map.w) + 0.5, map.origin.y + (c0 / map.w) + 0.5)


func spawn(type_id: int, n: int) -> void:
	for k in n:
		var p := _spawn_point()
		pools[type_id].spawn(p.x, p.y, rng)


## Spawns/despawns gradually toward `target` (spawning is rate limited so the
## horde pours in through the canyon mouths).
func approach_population(target: int) -> void:
	var diff := target - total()
	if diff > 0:
		for k in mini(diff, max_spawn_per_frame):
			var p := _spawn_point()
			pools[_random_type()].spawn(p.x, p.y, rng)
	elif diff < 0:
		var remove := mini(-diff, max_spawn_per_frame * 4)
		while remove > 0:
			for p in pools:
				if p.count > 0 and remove > 0:
					p.remove(p.count - 1)
					remove -= 1


func clear() -> void:
	for p in pools:
		p.count = 0
		p.upload()


func _process(delta: float) -> void:
	var dt := minf(delta, 1.0 / 30.0)
	if not paused:
		simulate(dt)
	var t0 := Time.get_ticks_usec()
	for p in pools:
		p.upload()
	upload_usec = Time.get_ticks_usec() - t0


func simulate(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	_dens_next.fill(0)
	_frame += 1
	# frame-constant inputs shared (read-only) by all worker chunks
	_f_dt = dt
	_f_dirx = field.dir_x
	_f_dirz = field.dir_z
	_f_dist = field.dist
	_f_blk = map.blocked
	_f_dens = _dens
	_f_dnext = _dens_next
	_chunk_pool.clear()
	_chunk_start.clear()
	for p in pools:
		var start := 0
		while start < p.count:
			_chunk_pool.append(p.type_id)
			_chunk_start.append(start)
			start += CHUNK
	var nchunks := _chunk_pool.size()
	_chunk_reached.resize(nchunks)
	_chunk_reached.fill(0)
	if nchunks > 0:
		if threaded and nchunks > 1:
			var gid := WorkerThreadPool.add_group_task(_sim_chunk, nchunks, -1, true, "swarm")
			WorkerThreadPool.wait_for_group_task_completion(gid)
		else:
			for ci in nchunks:
				_sim_chunk(ci)
	for r in _chunk_reached:
		reached_core += r
	var tmp := _dens
	_dens = _dens_next
	_dens_next = tmp
	sim_usec = Time.get_ticks_usec() - t0


## Simulates one chunk of up to CHUNK aliens of a single strain. Runs on worker
## threads: touches only its own slots; density splats may race (lost
## increments are harmless for a crowd-pressure estimate).
func _sim_chunk(ci: int) -> void:
	var pool := pools[_chunk_pool[ci]]
	var i0 := _chunk_start[ci]
	var i1 := mini(i0 + CHUNK, pool.count)
	var dt := _f_dt
	var w := map.w
	var ox := map.origin.x
	var oz := map.origin.y
	var max_x := float(map.w) - 0.501
	var max_z := float(map.h) - 0.501
	var dirx := _f_dirx
	var dirz := _f_dirz
	var dist := _f_dist
	var blk := _f_blk
	var dens := _f_dens
	var dnext := _f_dnext
	var dw := _dw
	var ds := _dscale
	var dmax_x := dw - 2
	var dmax_z := _dh - 2
	var spawn_cells := map.spawn_cells
	var n_spawn := spawn_cells.size()
	var reached := 0
	var seed_base := _frame * 7919 + ci * 104729

	var px := pool.px
	var pz := pool.pz
	var vx := pool.vx
	var vz := pool.vz
	var spd := pool.speed
	var sz := pool.size
	var buf := pool.buf
	var steer := minf(1.0, float(pool.def.steer) * dt)
	var mass := int(pool.def.mass)
	var sep := separation * float(pool.def.push)
	var spr := spread * float(pool.def.push)
	for i in range(i0, i1):
		# grid space (0..w, 0..h)
		var gx := px[i] - ox
		var gz := pz[i] - oz
		var cx := int(gx)
		var cz := int(gz)
		var c := cz * w + cx
		var s := spd[i]
		var tx := dirx[c] * s
		var tz := dirz[c] * s

		# crowd pressure from density gradient
		var fx := gx * ds
		var fz := gz * ds
		var dx := int(fx)
		var dz := int(fz)
		if dx < 1: dx = 1
		elif dx > dmax_x: dx = dmax_x
		if dz < 1: dz = 1
		elif dz > dmax_z: dz = dmax_z
		var di := dz * dw + dx
		tx += float(dens[di - 1] - dens[di + 1]) * sep
		tz += float(dens[di - dw] - dens[di + dw]) * sep
		var here := dens[di]
		if here > mass:
			var crowd := float(here) * spr
			tx += (fx - dx - 0.5) * crowd
			tz += (fz - dz - 0.5) * crowd

		# cap the desired speed so crowd pressure can't fling aliens
		var t2 := tx * tx + tz * tz
		var cap := s * 1.35
		if t2 > cap * cap:
			var ks := cap / sqrt(t2)
			tx *= ks
			tz *= ks

		var cvx := vx[i]
		var cvz := vz[i]
		cvx += (tx - cvx) * steer
		cvz += (tz - cvz) * steer
		var nx := gx + cvx * dt
		var nz := gz + cvz * dt
		if nx < 0.5: nx = 0.5
		elif nx > max_x: nx = max_x
		if nz < 0.5: nz = 0.5
		elif nz > max_z: nz = max_z

		# slide along walls (unless already inside one: then climb out)
		if blk[c] == 0:
			if blk[cz * w + int(nx)]:
				nx = gx
				cvx *= -0.2
			if blk[int(nz) * w + int(nx)]:
				nz = gz
				cvz *= -0.2

		if dist[int(nz) * w + int(nx)] == 0:
			# reached the core: the M1 test range recycles it to a canyon mouth
			reached += 1
			var hsh := (seed_base + i * 2654435761) & 0x7fffffff
			var sc := spawn_cells[hsh % n_spawn]
			nx = (sc % w) + float(hsh & 1023) / 1024.0
			nz = (sc / w) + float((hsh >> 10) & 1023) / 1024.0
			cvx = 0.0
			cvz = 0.0

		vx[i] = cvx
		vz[i] = cvz
		px[i] = nx + ox
		pz[i] = nz + oz
		dnext[int(nz * ds) * dw + int(nx * ds)] += mass

		var o := i * 16
		var sp2 := cvx * cvx + cvz * cvz
		if sp2 > 0.05:
			var k := sz[i] / sqrt(sp2)
			var sn := cvx * k
			var cs := cvz * k
			buf[o] = cs
			buf[o + 2] = sn
			buf[o + 8] = -sn
			buf[o + 10] = cs
		buf[o + 3] = nx + ox
		buf[o + 11] = nz + oz
	_chunk_reached[ci] = reached
