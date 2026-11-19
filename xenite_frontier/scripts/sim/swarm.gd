class_name Swarm
extends Node3D
## Simulates every alien in one tight pass per 1,024-alien chunk on worker
## threads:
##  1. burning / slow timers
##  2. sample the surface flow field, or the burrow field when tunnelling
##  3. strain traits: bash blocking structures, spitters shell structures
##     from range, burrowers surface near the core, brood mothers give birth,
##     abductors grab exposed colonists (Snatchers hunt them, even out of
##     turrets) and carriers drag them to the map edge, aliens stop to eat
##     corpses they stand on
##  4. crowd separation from a coarse density grid (previous frame), O(1)
##  5. steer, integrate, slide along solid cells (climb walls over corpse piles)
##  6. gnaw the core, splat density, bucket for the spatial grid, write the
##     MultiMesh buffer (position, facing, height, hit-flash decay)
## Each chunk writes events (deaths, structure hits, acid spits, broods) to its
## own arrays, which are merged on the main thread, so no locks are needed.

const CHUNK := 1024
const SHIFT := 17
const MASK := (1 << 17) - 1

var map: OutpostMap
var field: FlowField          # surface swarm
var bfield: FlowField         # tunnellers
var rfield: FlowField         # carriers: to the map edge (canyon mouths)
var hfield: FlowField         # Snatchers: toward exposed colonists / crews
var pools: Array[AlienPool] = []
var rng := RandomNumberGenerator.new()
var paused := false
var threaded := true
## benchmark mode: aliens reaching the core are recycled to a canyon mouth
var recycle_at_core := false

var separation := 2.2
var spread := 2.5
var wander := 0.45
var max_spawn_per_frame := 600
var surface_dist := 80
var grid_cell := 4.0

var sim_usec := 0
var upload_usec := 0
var reached_core := 0

# merged per-frame outputs
var out_dead := PackedInt32Array()       # handles that burned to death
var out_hit_cell := PackedInt32Array()   # structure cells being bashed
var out_hit_dmg := PackedFloat32Array()
var out_spit := PackedFloat32Array()     # [x, z, target_cell, damage]...
var out_brood := PackedFloat32Array()    # [x, z, mother_type]...
var out_grab := PackedInt32Array()       # [handle, colonist_id, mauls(0/1)]...
var out_eat := PackedInt32Array()        # [handle, cell]...
var out_escape := PackedInt32Array()     # [handle, colonist_id]...
var out_carried := PackedFloat32Array()  # [colonist_id, x, z]...
var core_damage := 0.0

var grid_w := 0
var grid_h := 0

var _dens := PackedInt32Array()
var _dens_next := PackedInt32Array()
var _dw := 0
var _dh := 0
var _dscale := 2.0
var _frame := 0
var _chunk_pool := PackedInt32Array()
var _chunk_start := PackedInt32Array()
var _c_reached := PackedInt32Array()
var _c_core := PackedFloat32Array()
var _c_dead: Array[PackedInt32Array] = []
var _c_hit_c: Array[PackedInt32Array] = []
var _c_hit_d: Array[PackedFloat32Array] = []
var _c_spit: Array[PackedFloat32Array] = []
var _c_brood: Array[PackedFloat32Array] = []
var _c_grab: Array[PackedInt32Array] = []
var _c_eat: Array[PackedInt32Array] = []
var _c_escape: Array[PackedInt32Array] = []
var _c_carried: Array[PackedFloat32Array] = []
var carrier_mult := 0.7
var hunt_sense := 140
var feed_time := 1.8
var _f_dt := 0.0
var _f_time := 0.0
var _weights := PackedFloat32Array()
var _weight_total := 0.0
var _burn_dps := 7.0


func setup(m: OutpostMap, f: FlowField, bf: FlowField, rf: FlowField, hf: FlowField, defs: Array) -> void:
	map = m
	field = f
	bfield = bf
	rfield = rf
	hfield = hf
	var col := GameConfig.colonists
	carrier_mult = float(col.get("carrier_speed_mult", carrier_mult))
	hunt_sense = int(float(col.get("hunt_sense_range", 14.0)) * FlowField.ORTHO)
	feed_time = float(GameConfig.feeding.get("feed_time", feed_time))
	var cfg := GameConfig.section("swarm")
	separation = cfg.get("separation", separation)
	spread = cfg.get("intra_cell_spread", spread)
	wander = cfg.get("wander", wander)
	max_spawn_per_frame = int(cfg.get("max_spawn_per_frame", max_spawn_per_frame))
	threaded = bool(cfg.get("threaded", true))
	_dscale = 1.0 / float(cfg.get("density_cell_size", 0.5))
	var cc := GameConfig.section("combat")
	surface_dist = int(float(cc.get("burrow_surface_distance", 8.0)) * FlowField.ORTHO)
	grid_cell = float(cc.get("grid_cell", 4.0))
	grid_w = int(ceil(map.w / grid_cell))
	grid_h = int(ceil(map.h / grid_cell))
	_dw = int(map.w * _dscale)
	_dh = int(map.h * _dscale)
	_dens.resize(_dw * _dh)
	_dens_next.resize(_dw * _dh)
	_dens.fill(0)
	for t in GameConfig.turret_defs:
		if t.id == "flamethrower":
			_burn_dps = float(t.get("burn_dps", _burn_dps))

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
	for attempt in 8:
		var c := cells[rng.randi() % cells.size()]
		if field.dist[c] < FlowField.UNREACHABLE:
			return Vector2(map.origin.x + (c % map.w) + rng.randf(), map.origin.y + (c / map.w) + rng.randf())
	var c0 := cells[rng.randi() % cells.size()]
	return Vector2(map.origin.x + (c0 % map.w) + 0.5, map.origin.y + (c0 / map.w) + 0.5)


func spawn_at(type_id: int, x: float, z: float) -> void:
	pools[type_id].spawn(x, z, rng)


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


func upload() -> void:
	var t0 := Time.get_ticks_usec()
	for p in pools:
		p.upload()
	upload_usec = Time.get_ticks_usec() - t0


func simulate(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	out_dead.clear()
	out_hit_cell.clear()
	out_hit_dmg.clear()
	out_spit.clear()
	out_brood.clear()
	out_grab.clear()
	out_eat.clear()
	out_escape.clear()
	out_carried.clear()
	core_damage = 0.0
	if paused:
		sim_usec = 0
		return
	_dens_next.fill(0)
	_frame += 1
	_f_dt = dt
	_f_time += dt
	_chunk_pool.clear()
	_chunk_start.clear()
	for p in pools:
		var start := 0
		while start < p.count:
			_chunk_pool.append(p.type_id)
			_chunk_start.append(start)
			start += CHUNK
	var nchunks := _chunk_pool.size()
	while _c_dead.size() < nchunks:
		_c_dead.append(PackedInt32Array())
		_c_hit_c.append(PackedInt32Array())
		_c_hit_d.append(PackedFloat32Array())
		_c_spit.append(PackedFloat32Array())
		_c_brood.append(PackedFloat32Array())
		_c_grab.append(PackedInt32Array())
		_c_eat.append(PackedInt32Array())
		_c_escape.append(PackedInt32Array())
		_c_carried.append(PackedFloat32Array())
	_c_reached.resize(nchunks)
	_c_core.resize(nchunks)
	if nchunks > 0:
		if threaded and nchunks > 1:
			var gid := WorkerThreadPool.add_group_task(_sim_chunk, nchunks, -1, true, "swarm")
			WorkerThreadPool.wait_for_group_task_completion(gid)
		else:
			for ci in nchunks:
				_sim_chunk(ci)
	for ci in nchunks:
		reached_core += _c_reached[ci]
		core_damage += _c_core[ci]
		out_dead.append_array(_c_dead[ci])
		out_hit_cell.append_array(_c_hit_c[ci])
		out_hit_dmg.append_array(_c_hit_d[ci])
		out_spit.append_array(_c_spit[ci])
		out_brood.append_array(_c_brood[ci])
		out_grab.append_array(_c_grab[ci])
		out_eat.append_array(_c_eat[ci])
		out_escape.append_array(_c_escape[ci])
		out_carried.append_array(_c_carried[ci])
	var tmp := _dens
	_dens = _dens_next
	_dens_next = tmp
	sim_usec = Time.get_ticks_usec() - t0


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
	var gdx := field.dir_x
	var gdz := field.dir_z
	var gdist := field.dist
	var bdx := bfield.dir_x
	var bdz := bfield.dir_z
	var bdist := bfield.dist
	var rdx := rfield.dir_x
	var rdz := rfield.dir_z
	var rdist := rfield.dist
	var hdx := hfield.dir_x
	var hdz := hfield.dir_z
	var hdist := hfield.dist
	var cat := map.colonist_at
	var crew_at := map.crew_at
	var ccount := map.corpse_count
	var solid := map.blocked
	var kind := map.kind
	var climb := map.climb
	var pile := map.pile
	var sheight := map.sheight
	var stype := map.stype
	var dens := _dens
	var dnext := _dens_next
	var dw := _dw
	var ds := _dscale
	var dmax_x := dw - 2
	var dmax_z := _dh - 2
	var gs := 1.0 / grid_cell
	var gw := grid_w
	var spawn_cells := map.spawn_cells
	var n_spawn := spawn_cells.size()
	var seed_base := _frame * 7919 + ci * 104729
	var frame := _frame
	var time := _f_time
	var surf := surface_dist
	var recycle := recycle_at_core

	var dead: PackedInt32Array = _c_dead[ci]
	var hit_c: PackedInt32Array = _c_hit_c[ci]
	var hit_d: PackedFloat32Array = _c_hit_d[ci]
	var spit: PackedFloat32Array = _c_spit[ci]
	var brood: PackedFloat32Array = _c_brood[ci]
	var grab: PackedInt32Array = _c_grab[ci]
	var eat: PackedInt32Array = _c_eat[ci]
	var escape: PackedInt32Array = _c_escape[ci]
	var carried: PackedFloat32Array = _c_carried[ci]
	dead.clear(); hit_c.clear(); hit_d.clear(); spit.clear(); brood.clear()
	grab.clear(); eat.clear(); escape.clear(); carried.clear()
	var reached := 0
	var core_dmg := 0.0

	var t := pool.type_id
	var hbase := t << SHIFT
	var def := pool.def
	var px := pool.px
	var pz := pool.pz
	var vx := pool.vx
	var vz := pool.vz
	var hp := pool.hp
	var spd := pool.speed
	var sz := pool.size
	var tmr := pool.timer
	var slw := pool.slow
	var brn := pool.burn
	var aux := pool.aux
	var tgt := pool.tgt
	var bkt := pool.bucket
	var buf := pool.buf
	var steer := minf(1.0, float(def.steer) * dt)
	var mass := int(def.mass)
	var sep := separation * float(def.push)
	var spr := spread * float(def.push)
	var sdps := float(def.get("structure_dps", 0.0)) * dt
	var door_mult := float(def.get("door_mult", 1.0))
	var cdps := float(def.get("core_dps", 0.0)) * dt
	var burn_dmg := _burn_dps * GameConfig.multiplier(t, GameConfig.Dmg.INCENDIARY) * dt
	var is_burrower := pool.burrows
	var rr := int(pool.ranged_range)
	var rcd := pool.ranged_cd
	var rdmg := pool.ranged_dmg
	var bint := pool.brood_interval
	var carry := pool.carry
	var feed := pool.feed
	var abducts := pool.abducts
	var mauls := pool.mauls
	var hunts := pool.hunts
	var grabs := abducts or mauls
	var feed_chance := int(pool.feed_rate * dt * 100000.0)
	var ftime := feed_time
	var cmult := carrier_mult
	var sense := hunt_sense

	for i in range(i0, i1):
		var o := i * 16
		# ---- status effects
		var b := brn[i]
		if b > 0.0:
			var hh := hp[i] - burn_dmg
			hp[i] = hh
			brn[i] = b - dt
			if hh <= 0.0:
				dead.append(hbase | i)
				continue
		var gx := px[i] - ox
		var gz := pz[i] - oz
		var cx := int(gx)
		var cz := int(gz)
		var c := cz * w + cx
		var s := spd[i]
		var sl := slw[i]
		if sl > 0.0:
			s *= 0.45
			slw[i] = sl - dt
		var tm := tmr[i] - dt

		# ---- which field
		var burrowed := false
		if is_burrower:
			burrowed = aux[i] > 0.5
			if burrowed and bdist[c] < surf:
				aux[i] = 0.0
				burrowed = false
			elif not burrowed and tm <= 0.0 and bdist[c] >= surf and kind[c] != OutpostMap.Kind.ROCK:
				aux[i] = 1.0
				burrowed = true
		var cid := carry[i]
		var carrying := cid >= 0
		var fdx: float
		var fdz: float
		if carrying:
			# dragging a colonist to the map edge
			fdx = rdx[c]
			fdz = rdz[c]
			s *= cmult
		elif burrowed:
			fdx = bdx[c]
			fdz = bdz[c]
		elif hunts and hdist[c] < sense:
			fdx = hdx[c]
			fdz = hdz[c]
		else:
			fdx = gdx[c]
			fdz = gdz[c]

		var wv := sin(time * 1.7 + float(i) * 0.6180339) * s * wander
		var tx := fdx * s - fdz * wv
		var tz := fdz * s + fdx * wv

		# ---- strain behaviour
		var fd := feed[i]
		if not burrowed:
			var ac := int(gz + fdz * 0.8) * w + int(gx + fdx * 0.8)
			if grabs and not carrying and fd <= 0.0:
				var col := cat[c]
				if col == 0:
					col = cat[ac]
				if col > 0:
					grab.append(hbase | i); grab.append(col - 1); grab.append(1 if mauls else 0)
				elif hunts and crew_at[ac] > 0:
					# Snatcher rips the crew out of a turret
					grab.append(hbase | i); grab.append(crew_at[ac] - 1); grab.append(0)
			if fd > 0.0:
				# eating: stand still until the meal is done
				fd -= dt
				tx = 0.0
				tz = 0.0
				if fd <= 0.0:
					eat.append(hbase | i); eat.append(c)
			elif feed_chance > 0 and not carrying and ccount[c] > 0 \
					and ((seed_base + i * 7919) % 100000) < feed_chance:
				fd = ftime
			elif ac != c and kind[ac] == OutpostMap.Kind.STRUCT and climb[ac] == 0:
				# blocked by a structure the field wants us through: bash it
				hit_c.append(ac)
				hit_d.append(sdps * (door_mult if stype[ac] == OutpostMap.SType.DOOR else 1.0))
				tx *= 0.15
				tz *= 0.15
			elif rr > 0:
				var tg := tgt[i]
				if ((i + frame) & 7) == 0:
					tg = -1
					var mx := gx
					var mz := gz
					for step in rr:
						mx += fdx
						mz += fdz
						var mc := int(mz) * w + int(mx)
						if mc < 0 or mc >= solid.size() or kind[mc] == OutpostMap.Kind.ROCK:
							break
						if kind[mc] == OutpostMap.Kind.STRUCT:
							tg = mc
							break
					tgt[i] = tg
				if tg >= 0:
					if kind[tg] != OutpostMap.Kind.STRUCT:
						tgt[i] = -1
					else:
						tx = 0.0
						tz = 0.0
						if tm <= 0.0:
							tm = rcd
							spit.append(px[i]); spit.append(pz[i])
							spit.append(float(tg)); spit.append(rdmg)
		feed[i] = fd
		if bint > 0.0 and tm <= 0.0:
			tm = bint
			brood.append(px[i]); brood.append(pz[i]); brood.append(float(t))
		tmr[i] = tm

		# ---- crowd pressure from density gradient
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
		var t2 := tx * tx + tz * tz
		var cap := s * 1.35
		if t2 > cap * cap:
			var ks := cap / sqrt(t2)
			tx *= ks
			tz *= ks

		# ---- integrate + collide
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
		if burrowed:
			if kind[c] != OutpostMap.Kind.ROCK:
				if kind[cz * w + int(nx)] == OutpostMap.Kind.ROCK:
					nx = gx
					cvx *= -0.2
				if kind[int(nz) * w + int(nx)] == OutpostMap.Kind.ROCK:
					nz = gz
					cvz *= -0.2
		elif solid[c] == 0 or climb[c] == 1:
			var tc := cz * w + int(nx)
			if solid[tc] == 1 and climb[tc] == 0:
				nx = gx
				cvx *= -0.2
			tc = int(nz) * w + int(nx)
			if solid[tc] == 1 and climb[tc] == 0:
				nz = gz
				cvz *= -0.2

		var ncell := int(nz) * w + int(nx)
		if carrying:
			carried.append(float(cid)); carried.append(nx + ox); carried.append(nz + oz)
			if rdist[ncell] == 0:
				escape.append(hbase | i); escape.append(cid)
		elif not burrowed and gdist[ncell] == 0:
			if recycle:
				reached += 1
				var hsh := (seed_base + i * 2654435761) & 0x7fffffff
				var sc := spawn_cells[hsh % n_spawn]
				nx = (sc % w) + float(hsh & 1023) / 1024.0
				nz = (sc / w) + float((hsh >> 10) & 1023) / 1024.0
				ncell = int(nz) * w + int(nx)
				cvx = 0.0
				cvz = 0.0
			else:
				core_dmg += cdps

		vx[i] = cvx
		vz[i] = cvz
		px[i] = nx + ox
		pz[i] = nz + oz
		dnext[int(nz * ds) * dw + int(nx * ds)] += mass
		bkt[i] = int(nz * gs) * gw + int(nx * gs)

		# ---- render buffer
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
		var y := 0.0
		if burrowed:
			y = -0.55 * sz[i]
		elif kind[ncell] == OutpostMap.Kind.STRUCT:
			y = sheight[ncell]
		else:
			y = pile[ncell] * 0.85
		buf[o + 7] = y
		var fl := buf[o + 12]
		if fl > 0.0:
			buf[o + 12] = maxf(0.0, fl - dt * 7.0)
	_c_reached[ci] = reached
	_c_core[ci] = core_dmg
