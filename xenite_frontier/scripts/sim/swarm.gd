class_name Swarm
extends Node3D
## Simulates every alien in one tight pass per 1,024-alien chunk on worker
## threads:
##  1. burning / slow timers
##  2. sample the surface flow field, or the burrow field when tunnelling
##  3. strain traits (concept sheet "Humanoid Lineup v4 - movement notes"):
##     bash blocking structures; Spitters hang back at max range, inflate
##     their sac for 1 s (tell), lob acid, and retreat to refill after three
##     shots; Burrowers tunnel, crack the ground for 2 s (tell), erupt and rake
##     for 3 s, then sink again; Maulers lock onto a door and charge it in a
##     straight line they cannot turn out of (stunned on impact); Elders stop
##     to roar and enrage the aliens around them; Snatchers hunt the most
##     isolated colonist, zig-zag under fire and drag their catch backward at
##     half speed; Brood Mothers eat every corpse they pass and shed clinging
##     young as runts; runts skitter in bursts, freeze and pounce, and climb
##     corpse piles before anyone else; aliens stop to eat corpses
##  4. crowd separation from a coarse density grid (previous frame), O(1)
##  5. steer, integrate, slide along solid cells (climb walls over corpse piles)
##  6. gnaw the core, splat density, bucket for the spatial grid, write the
##     MultiMesh buffer (position, facing, height, hit-flash decay)
## Each chunk writes events (deaths, structure hits, acid spits, broods) to its
## own arrays, which are merged on the main thread, so no locks are needed.

const CHUNK := 512
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
var hp_mult := 1.0            # waves toughen the swarm (waves.json hp_growth_per_wave)
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
var out_step := PackedFloat32Array()     # heavy footfalls [x, z, strength]...
var out_act := PackedFloat32Array()      # behaviour events [kind, x, z, a, type]...
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
var _c_step: Array[PackedFloat32Array] = []
var _c_act: Array[PackedFloat32Array] = []
## out_act kinds
enum Act { CRACK = 1, ERUPT, SINK, IMPACT, ROAR, TELL_SPIT }
var rage_speed := 1.4
var rage_damage := 1.6
## where the camera looks (footfalls further than 30 m away aren't reported)
var listen := Vector2(1e9, 1e9)
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
	for d: Dictionary in defs:
		if d.has("roar"):
			rage_speed = float(d.roar.get("speed_mult", rage_speed))
			rage_damage = float(d.roar.get("damage_mult", rage_damage))

	var shader := preload("res://scripts/render/alien.gdshader")
	for i in defs.size():
		# per-strain material: joint pivots and gait for the GPU animation
		var mat := ShaderMaterial.new()
		mat.shader = shader
		var rig := AlienMeshes.rig(defs[i].id)
		for k: String in rig:
			mat.set_shader_parameter(k, rig[k])
		if int(defs[i].get("brood", {}).get("young_max", 0)) > 0:
			mat.set_shader_parameter("young_n", float(AlienMeshes.YOUNG_N))
		var near: Mesh = AlienMeshes.build(defs[i].id, 0)
		var far: Mesh = AlienMeshes.build(defs[i].id, 1)
		# art hook: "mesh": "res://art/<name>.glb" in aliens.json replaces the
		# procedural model (see README "Using your own models")
		var custom := _load_custom_mesh(str(defs[i].get("mesh", "")))
		if custom:
			near = custom
			far = custom
		var pool := AlienPool.new(i, defs[i], near, mat)
		pool.mesh_near = near
		pool.mesh_far = far
		pool.stride = float(rig.get("gait_freq", 10.0)) / maxf(0.5, float(defs[i].speed))
		pools.append(pool)
		add_child(pool.instance)
		_weights.append(float(defs[i].get("spawn_weight", 1)))
		_weight_total += _weights[i]


## Swap to the low-detail meshes when the camera is far out.
var far_lod := false
func set_far_lod(far: bool) -> void:
	if far == far_lod:
		return
	far_lod = far
	for p in pools:
		p.multimesh.mesh = p.mesh_far if far else p.mesh_near


static func _load_custom_mesh(path: String) -> Mesh:
	if path == "" or not ResourceLoader.exists(path):
		if path != "":
			push_warning("aliens.json: mesh '%s' not found, using the procedural model" % path)
		return null
	var res := load(path)
	if res is Mesh:
		return res
	if res is PackedScene:
		var inst: Node = (res as PackedScene).instantiate()
		var found: Mesh = null
		for n in inst.find_children("*", "MeshInstance3D", true, false):
			found = (n as MeshInstance3D).mesh
			break
		inst.free()
		return found
	return null


func total() -> int:
	var t := 0
	for p in pools:
		t += p.count
	return t


## Dev: random spawns use only this strain (`-- --strain=<id>`).
func only_strain(t: int) -> void:
	_weight_total = 0.0
	for i in _weights.size():
		_weights[i] = 1.0 if i == t else 0.0
		_weight_total += _weights[i]


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
	pools[type_id].spawn(x, z, rng, hp_mult)


## A wave pack: all leave the same canyon mouth together and share a lane.
func spawn_pack(types: PackedInt32Array, mouth: int) -> void:
	var cells: PackedInt32Array = map.mouth_cells[mouth] if mouth < map.mouth_cells.size() else map.spawn_cells
	var lane_base := rng.randf_range(-0.8, 0.8)
	var anchor := cells[rng.randi() % cells.size()]
	for t in types:
		var c := cells[rng.randi() % cells.size()]
		if rng.randf() < 0.6:
			c = anchor
		var x := map.origin.x + (c % map.w) + rng.randf()
		var z := map.origin.y + (c / map.w) + rng.randf()
		pools[t].spawn(x, z, rng, hp_mult, clampf(lane_base + rng.randf_range(-0.25, 0.25), -1.0, 1.0))


## Spawns n aliens of random strains (spawn weights) at the canyon mouths.
func spawn_random(n: int) -> void:
	for k in n:
		var p := _spawn_point()
		pools[_random_type()].spawn(p.x, p.y, rng, hp_mult)


## Spawns/despawns gradually toward `target` (spawning is rate limited so the
## horde pours in through the canyon mouths).
func approach_population(target: int) -> void:
	var diff := target - total()
	if diff > 0:
		for k in mini(diff, max_spawn_per_frame):
			var p := _spawn_point()
			pools[_random_type()].spawn(p.x, p.y, rng, hp_mult)
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
	out_step.clear()
	out_act.clear()
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
		_c_step.append(PackedFloat32Array())
		_c_act.append(PackedFloat32Array())
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
		out_step.append_array(_c_step[ci])
		out_act.append_array(_c_act[ci])
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
	var hdx_f := hfield.dir_x
	var hdz_f := hfield.dir_z
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
	var hg := map.hgrid
	var hgw := map.hw
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
	var n_cells := solid.size()

	var dead: PackedInt32Array = _c_dead[ci]
	var hit_c: PackedInt32Array = _c_hit_c[ci]
	var hit_d: PackedFloat32Array = _c_hit_d[ci]
	var spit: PackedFloat32Array = _c_spit[ci]
	var brood: PackedFloat32Array = _c_brood[ci]
	var grab: PackedInt32Array = _c_grab[ci]
	var eat: PackedInt32Array = _c_eat[ci]
	var escape: PackedInt32Array = _c_escape[ci]
	var carried: PackedFloat32Array = _c_carried[ci]
	var steps: PackedFloat32Array = _c_step[ci]
	var acts: PackedFloat32Array = _c_act[ci]
	dead.clear(); hit_c.clear(); hit_d.clear(); spit.clear(); brood.clear()
	grab.clear(); eat.clear(); escape.clear(); carried.clear(); steps.clear(); acts.clear()
	var reached := 0
	var core_dmg := 0.0

	var t := pool.type_id
	var tf := float(t)
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
	var sniff_chance := int(0.07 * dt * 100000.0)
	var sense := hunt_sense
	var stk := pool.stuck
	var lane := pool.lane
	var gait := pool.gait
	var stride := pool.stride
	# v4 behaviour
	var mode := pool.mode
	var mt := pool.mt
	var val := pool.val
	var hx := pool.hdx
	var hz := pool.hdz
	var rage := pool.rage
	var alert := pool.alert
	var cool := pool.cool
	var tell_t := maxf(0.01, pool.tell_time)
	var shots := float(pool.shots)
	var refill := maxf(0.01, pool.refill)
	var back_off := pool.back_off
	var charges := pool.charge_range > 0
	var ch_rng := pool.charge_range
	var ch_min := pool.charge_min
	var ch_mult := pool.charge_mult
	var ch_max := maxf(0.01, pool.charge_max)
	var ch_imp := pool.charge_impact
	var ch_door := pool.charge_door_mult
	var ch_dstun := pool.charge_door_stun
	var ch_stun := pool.charge_stun
	var ch_cd := pool.charge_cd
	var roars := pool.roar_interval > 0.0
	var roar_int := pool.roar_interval
	var surf_time := pool.surface_time
	var tun_min := pool.tunnel_min
	var tell_spd := pool.tell_speed
	var drag := pool.drag_mult if pool.drag_mult > 0.0 else carrier_mult
	var drag_back := pool.drag_mult > 0.0
	var zig := pool.zigzag
	var ign_t := pool.ignores_turrets
	var bursts := pool.burst_run > 0.0
	var b_run := pool.burst_run
	var b_frz := pool.burst_freeze
	var b_pr := int(pool.pounce_range * FlowField.ORTHO)
	var b_pcell := int(pool.pounce_range)
	var b_pm := pool.pounce_mult
	var climb_h := map.climb_height * pool.climb_mult
	var runt_climb := pool.climb_mult > 0.0
	var heavy := pool.heavy_steps
	var feed_all := pool.feed_every
	var feed_cd := pool.feed_cooldown
	var young := pool.young_max > 0
	var young_max := maxf(1.0, float(pool.young_max))
	var ray_c := PackedFloat32Array([1.0, cos(0.6), cos(0.6)])
	var ray_s := PackedFloat32Array([0.0, -sin(0.6), sin(0.6)])
	var sweep := pool.sweep
	var behaves := is_burrower or charges or roars or rr > 0 or bursts
	var acts_special := charges or roars or rr > 0 or bursts
	var lx_ := listen.x - ox
	var lz_ := listen.y - oz
	var rg_spd := rage_speed
	var rg_dmg := rage_damage
	const M_NONE := AlienPool.Mode.NONE
	const M_TELL := AlienPool.Mode.TELL
	const M_CHARGE := AlienPool.Mode.CHARGE
	const M_STUN := AlienPool.Mode.STUN
	const M_RETREAT := AlienPool.Mode.RETREAT
	const M_SURF := AlienPool.Mode.SURFACED
	const M_FREEZE := AlienPool.Mode.FREEZE
	const M_POUNCE := AlienPool.Mode.POUNCE
	const K_GROUND := OutpostMap.Kind.GROUND
	const K_ROCK := OutpostMap.Kind.ROCK
	const K_STRUCT := OutpostMap.Kind.STRUCT

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
		var dmul := 1.0
		var rg := rage[i]
		if rg > 0.0:
			rage[i] = rg - dt
			s *= rg_spd
			dmul = rg_dmg
		var tm := tmr[i] - dt
		var m := M_NONE
		var mtv := 0.0
		if behaves:
			m = mode[i]
			mtv = mt[i]
		var legit := false   # standing still on purpose (eating, bashing, shelling, gnawing, tells)
		var pose := 0.0      # render: see alien.gdshader (state channel)
		var face := false    # render facing from (fcx, fcz) instead of velocity
		var fcx := 0.0
		var fcz := 0.0
		var free_run := false  # charging: no crowd pressure, no speed cap, no steering lag
		var extra := 0.0

		# ---- burrower cycle: tunnel -> 2 s ground-crack tell -> erupt and rake 3 s -> sink
		var burrowed := false
		if is_burrower:
			burrowed = aux[i] > 0.5
			if burrowed:
				if m == M_TELL:
					mtv -= dt
					s *= tell_spd
					legit = true
					pose = -4.0 - minf(0.99, 1.0 - mtv / tell_t)
					if mtv <= 0.0:
						if kind[c] == K_GROUND:
							aux[i] = 0.0
							burrowed = false
							m = M_SURF
							mtv = surf_time
							acts.append(Act.ERUPT); acts.append(px[i]); acts.append(pz[i]); acts.append(sz[i]); acts.append(tf)
						else:
							mtv = 0.05   # keep heaving until it is under open ground
				else:
					var cl := cool[i] - dt
					cool[i] = cl
					if cl <= 0.0 and bdist[c] < surf and kind[c] == K_GROUND:
						m = M_TELL
						mtv = tell_t
						acts.append(Act.CRACK); acts.append(px[i]); acts.append(pz[i]); acts.append(sz[i]); acts.append(tf)
			elif m == M_STUN:
				mtv -= dt
				if mtv <= 0.0:
					m = M_SURF
					mtv = surf_time
			else:
				if m != M_SURF:
					m = M_SURF
					mtv = surf_time
				mtv -= dt
				if mtv <= 0.0 and kind[c] == K_GROUND and carry[i] < 0:
					aux[i] = 1.0
					burrowed = true
					m = M_NONE
					cool[i] = tun_min
					acts.append(Act.SINK); acts.append(px[i]); acts.append(pz[i]); acts.append(sz[i]); acts.append(tf)

		var cid := carry[i]
		var carrying := cid >= 0
		var fdx: float
		var fdz: float
		if carrying:
			# dragging a colonist to the map edge
			fdx = rdx[c]
			fdz = rdz[c]
			s *= drag
		elif burrowed:
			fdx = bdx[c]
			fdz = bdz[c]
		elif hunts and hdist[c] < sense:
			fdx = hdx_f[c]
			fdz = hdz_f[c]
		else:
			fdx = gdx[c]
			fdz = gdz[c]

		# persistent lane across the flow (packs share one) + slow weave
		var wv := (lane[i] * 0.6 + sin(time * 0.55 + float(i) * 0.6180339) * 0.3) * s * wander
		var tx := fdx * s - fdz * wv
		var tz := fdz * s + fdx * wv
		# Snatchers zig-zag while they are being shot at
		if zig > 0.0:
			var al := alert[i]
			if al > 0.0:
				alert[i] = al - dt
				if not carrying:
					var zz := sin(time * 7.5 + float(i) * 1.7) * s * zig
					tx -= fdz * zz
					tz += fdx * zz

		# ---- strain behaviour
		var fd := feed[i]
		if not burrowed:
			var ac := int(gz + fdz * 0.8) * w + int(gx + fdx * 0.8)
			if grabs and not carrying and fd <= 0.0 and m != M_STUN:
				var col := cat[c]
				if col == 0:
					col = cat[ac]
				if col > 0:
					grab.append(hbase | i); grab.append(col - 1); grab.append(1 if mauls else 0)
				elif hunts and not ign_t and crew_at[ac] > 0:
					# (pre-v4 Snatchers ripped crews out of turrets)
					grab.append(hbase | i); grab.append(crew_at[ac] - 1); grab.append(0)
			var busy := false
			if m == M_STUN:
				# dazed after a charge impact / forced up by seismic charges
				if not is_burrower:
					mtv -= dt
					if mtv <= 0.0:
						m = M_NONE
				tx = 0.0
				tz = 0.0
				legit = true
				pose = -8.0
				busy = true
			elif fd < 0.0:
				# sniffing the air / ground for prey: a short pause in the open
				fd = minf(0.0, fd + dt)
				tx *= 0.05
				tz *= 0.05
				legit = true
				pose = -1.0
				busy = true
			elif fd > 0.0:
				# eating: stand still until the meal is done
				fd -= dt
				tx = 0.0
				tz = 0.0
				legit = true
				pose = -1.0
				busy = true
				if fd <= 0.0:
					eat.append(hbase | i); eat.append(c)
					cool[i] = feed_cd
			if not busy and acts_special:
				if charges and not carrying:
					# Mauler: lock onto a door ahead, wind up, then charge in a
					# straight line it cannot turn out of
					if m == M_CHARGE:
						mtv -= dt
						var lx := gx + hx[i] * 0.7
						var lz := gz + hz[i] * 0.7
						var hit_rock := lx < 0.5 or lz < 0.5 or lx > max_x or lz > max_z
						var lc := int(lz) * w + int(lx)
						if not hit_rock:
							hit_rock = kind[lc] == K_ROCK
						if not hit_rock and kind[lc] == K_STRUCT and climb[lc] == 0:
							var door := stype[lc] == OutpostMap.SType.DOOR
							hit_c.append(lc)
							hit_d.append(ch_imp * (ch_door if door else 1.0) * dmul)
							m = M_STUN
							mtv = ch_dstun if door else ch_stun
							cool[i] = ch_cd
							acts.append(Act.IMPACT); acts.append(gx + hx[i] * 0.5 + ox); acts.append(gz + hz[i] * 0.5 + oz); acts.append(1.0 if door else 0.0); acts.append(tf)
						elif hit_rock or mtv <= 0.0:
							m = M_STUN if hit_rock else M_NONE
							mtv = ch_stun
							cool[i] = ch_cd
						if m == M_CHARGE:
							tx = hx[i] * s * ch_mult
							tz = hz[i] * s * ch_mult
							free_run = true
							pose = -6.0 - minf(0.99, 1.0 - mtv / ch_max)
						else:
							tx = 0.0
							tz = 0.0
							pose = -8.0 if m == M_STUN else 0.0
						legit = true
						busy = true
					elif m == M_TELL:
						mtv -= dt
						tx = 0.0
						tz = 0.0
						face = true
						fcx = hx[i]
						fcz = hz[i]
						legit = true
						busy = true
						pose = -4.0 - minf(0.99, 1.0 - mtv / tell_t)
						if mtv <= 0.0:
							m = M_CHARGE
							mtv = ch_max
					else:
						var cl := cool[i] - dt
						cool[i] = cl
						if cl <= 0.0 and ((i + frame) & 15) == 0 and gdist[c] < 600:
							var mx := gx
							var mz := gz
							for step in ch_rng:
								mx += fdx
								mz += fdz
								if mx < 0.5 or mz < 0.5 or mx > max_x or mz > max_z:
									break
								var mc := int(mz) * w + int(mx)
								if kind[mc] == K_ROCK:
									break
								if kind[mc] == K_STRUCT and climb[mc] == 0:
									if step + 1 >= ch_min:
										var ddx := float(mc % w) + 0.5 - gx
										var ddz := float(mc / w) + 0.5 - gz
										var dl := sqrt(ddx * ddx + ddz * ddz)
										if dl > 0.01:
											hx[i] = ddx / dl
											hz[i] = ddz / dl
											m = M_TELL
											mtv = tell_t
									break
				if not busy and roars:
					# Elder: plods, then stops to roar and enrage the aliens nearby
					if m == M_TELL:
						mtv -= dt
						tx = 0.0
						tz = 0.0
						legit = true
						busy = true
						pose = -4.0 - minf(0.99, 1.0 - mtv / tell_t)
						if mtv <= 0.0:
							m = M_NONE
							cool[i] = roar_int
							acts.append(Act.ROAR); acts.append(px[i]); acts.append(pz[i]); acts.append(sz[i]); acts.append(tf)
					else:
						var cl := cool[i] - dt
						cool[i] = cl
						if cl <= 0.0 and gdist[c] < 700:
							m = M_TELL
							mtv = tell_t
				if not busy and rr > 0:
					# Spitter: hang back at max range, 1 s sac tell, three shots, refill
					if m == M_RETREAT:
						mtv -= dt
						tx = -fdx * s * 0.8
						tz = -fdz * s * 0.8
						legit = true
						busy = true
						if mtv <= 0.0:
							m = M_NONE
							val[i] = shots
					else:
						var tg := tgt[i]
						if ((i + frame) & 15) == 0 and gdist[c] < 600:
							# three rays fanned around the path: turrets first, then the
							# nearest structure; with nothing in between, the Command Hab
							tg = -1
							var best_d := 1 << 20
							var best_turret := false
							var core_c := -1
							for ray in 3:
								var rx := fdx * ray_c[ray] - fdz * ray_s[ray]
								var rz := fdx * ray_s[ray] + fdz * ray_c[ray]
								var mx := gx
								var mz := gz
								for step in rr:
									mx += rx
									mz += rz
									if mx < 0.5 or mz < 0.5 or mx > max_x or mz > max_z:
										break
									var mc := int(mz) * w + int(mx)
									if kind[mc] == K_STRUCT:
										var is_t := stype[mc] == OutpostMap.SType.TURRET
										if (is_t and not best_turret) or (is_t == best_turret and step < best_d):
											tg = mc
											best_d = step
											best_turret = is_t
										break
									if gdist[mc] == 0:
										core_c = mc
										break
									if kind[mc] == K_ROCK:
										break
							if tg < 0 and core_c >= 0:
								tg = n_cells + core_c
							tgt[i] = tg
						if tg >= 0 and tg < n_cells and kind[tg] != K_STRUCT:
							tg = -1
							tgt[i] = -1
						if tg >= 0:
							var tcell := tg if tg < n_cells else tg - n_cells
							var ddx := float(tcell % w) + 0.5 - gx
							var ddz := float(tcell / w) + 0.5 - gz
							var dl := maxf(0.01, sqrt(ddx * ddx + ddz * ddz))
							face = true
							fcx = ddx / dl
							fcz = ddz / dl
							legit = true
							busy = true
							if m == M_TELL:
								mtv -= dt
								tx = 0.0
								tz = 0.0
								pose = -4.0 - minf(0.99, 1.0 - mtv / tell_t)
								if mtv <= 0.0:
									m = M_NONE
									tm = rcd
									spit.append(px[i]); spit.append(pz[i])
									spit.append(float(tg) if tg < n_cells else -1.0); spit.append(rdmg)
									val[i] -= 1.0
									if val[i] <= 0.0:
										m = M_RETREAT
										mtv = refill
							else:
								if dl < float(rr) * back_off:
									# too close to the guns: wade back out to max range
									tx = -fdx * s * 0.6
									tz = -fdz * s * 0.6
								else:
									tx = 0.0
									tz = 0.0
								if tm <= 0.0 and val[i] > 0.0:
									m = M_TELL
									mtv = tell_t
									acts.append(Act.TELL_SPIT); acts.append(px[i]); acts.append(pz[i]); acts.append(sz[i]); acts.append(tf)
						elif m == M_TELL:
							m = M_NONE
				if not busy and bursts and not carrying:
					# Runt: skitter, freeze, pounce
					if m == M_FREEZE:
						mtv -= dt
						tx = 0.0
						tz = 0.0
						legit = true
						busy = true
						if mtv <= 0.0:
							var pc := int(gz + fdz * b_pcell) * w + int(gx + fdx * b_pcell)
							var prey := gdist[c] < b_pr or (pc >= 0 and pc < n_cells and (kind[pc] == K_STRUCT or cat[pc] > 0))
							if prey:
								m = M_POUNCE
								mtv = 0.45
							else:
								m = M_NONE
								mtv = b_run * (0.6 + float((i * 37 + frame) % 10) * 0.08)
					elif m == M_POUNCE:
						mtv -= dt
						tx *= b_pm
						tz *= b_pm
						free_run = true
						pose = -2.0
						if mtv <= 0.0:
							m = M_NONE
							mtv = b_run
					else:
						mtv -= dt
						if mtv <= 0.0:
							m = M_FREEZE
							mtv = b_frz * (0.7 + float((i * 13 + frame) % 10) * 0.06)
			if not busy:
				var fed := false
				if feed_all and not carrying and cool[i] <= 0.0:
					# Brood Mother: stops to feed on every corpse she passes
					if ccount[c] > 0:
						fd = ftime
						fed = true
					else:
						for nb: int in [c - 1, c + 1, c - w, c + w]:
							if nb >= 0 and nb < n_cells and ccount[nb] > 0 and kind[nb] == K_GROUND:
								tx = (float(nb % w) + 0.5 - gx) * s * 0.8
								tz = (float(nb / w) + 0.5 - gz) * s * 0.8
								fed = true
								break
				if fed:
					pass
				elif feed_chance > 0 and not feed_all and not carrying and ccount[c] > 0 \
						and ((seed_base + i * 7919) % 100000) < feed_chance:
					fd = ftime
				elif not carrying and gdist[c] > 350 and ((seed_base + i * 104723) % 100000) < sniff_chance:
					fd = -(0.6 + float((i * 31) % 10) * 0.1)
				elif ac != c and kind[ac] == K_STRUCT and climb[ac] == 0 and not (runt_climb and pile[c] >= climb_h):
					# blocked by a structure the field wants us through: bash it
					var dmg := sdps * dmul
					hit_c.append(ac)
					hit_d.append(dmg * (door_mult if stype[ac] == OutpostMap.SType.DOOR else 1.0))
					if sweep > 0:
						# Elder: wide fist sweeps hit the cells either side too
						var sxo := int(roundf(-fdz))
						var szo := int(roundf(fdx))
						for side: int in [-1, 1]:
							var sc := ac + side * (szo * w + sxo)
							if sc >= 0 and sc < n_cells and kind[sc] == K_STRUCT:
								hit_c.append(sc)
								hit_d.append(dmg)
					tx *= 0.15
					tz *= 0.15
					legit = true
					pose = -2.0
		feed[i] = fd
		if bint > 0.0 and tm <= 0.0:
			tm = bint
			# young cling to the Brood Mother and drop off one at a time
			if not young:
				brood.append(px[i]); brood.append(pz[i]); brood.append(tf)
			elif val[i] >= 1.0:
				val[i] -= 1.0
				brood.append(px[i]); brood.append(pz[i]); brood.append(tf)
		if young:
			extra = clampf(val[i] / young_max, 0.0, 1.0)
		elif shots > 0.0:
			# Spitter sac: drains with each shot, refills while it retreats
			extra = clampf(mtv / refill, 0.0, 1.0) if m == M_RETREAT else 1.0 - clampf(val[i] / shots, 0.0, 1.0)
		tmr[i] = tm
		if behaves:
			mode[i] = m
			mt[i] = mtv

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
		if not free_run:
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
		if free_run:
			cvx = tx
			cvz = tz
		else:
			cvx += (tx - cvx) * steer
			cvz += (tz - cvz) * steer
		var nx := gx + cvx * dt
		var nz := gz + cvz * dt
		if nx < 0.5: nx = 0.5
		elif nx > max_x: nx = max_x
		if nz < 0.5: nz = 0.5
		elif nz > max_z: nz = max_z
		if burrowed:
			if kind[c] != K_ROCK:
				if kind[cz * w + int(nx)] == K_ROCK:
					nx = gx
					cvx *= -0.2
				if kind[int(nz) * w + int(nx)] == K_ROCK:
					nz = gz
					cvz *= -0.2
		elif solid[c] == 0 or climb[c] == 1:
			# runts scramble up walls on piles too low for anyone else
			var over := runt_climb and pile[c] >= climb_h
			var tc := cz * w + int(nx)
			if solid[tc] == 1 and climb[tc] == 0 and not (over and kind[tc] == K_STRUCT):
				nx = gx
				cvx *= -0.2
			tc = int(nz) * w + int(nx)
			if solid[tc] == 1 and climb[tc] == 0 and not (over and kind[tc] == K_STRUCT):
				nz = gz
				cvz *= -0.2

		var ncell := int(nz) * w + int(nx)
		if carrying:
			carried.append(float(cid)); carried.append(nx + ox); carried.append(nz + oz)
			if rdist[ncell] == 0:
				escape.append(hbase | i); escape.append(cid)
			if drag_back:
				# drags its catch backward: it faces the way it came
				face = true
				fcx = -cvx
				fcz = -cvz
				pose = -6.0
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
				core_dmg += cdps * dmul
				legit = true
				if pose > -3.5:
					pose = -2.0

		var mvx := nx - gx
		var mvz := nz - gz
		if legit or mvx * mvx + mvz * mvz > 0.04 * s * s * dt * dt:
			stk[i] = 0.0
		else:
			stk[i] += dt
		vx[i] = cvx
		vz[i] = cvz
		px[i] = nx + ox
		pz[i] = nz + oz
		dnext[int(nz * ds) * dw + int(nx * ds)] += mass
		bkt[i] = int(nz * gs) * gw + int(nx * gs)

		# ---- render buffer
		var sp2 := cvx * cvx + cvz * cvz
		if face and fcx * fcx + fcz * fcz > 0.0001:
			var kf := sz[i] / sqrt(fcx * fcx + fcz * fcz)
			buf[o] = fcz * kf
			buf[o + 2] = fcx * kf
			buf[o + 8] = -fcx * kf
			buf[o + 10] = fcz * kf
		elif sp2 > 0.05:
			var k := sz[i] / sqrt(sp2)
			var sn := cvx * k
			var cs := cvz * k
			buf[o] = cs
			buf[o + 2] = sn
			buf[o + 8] = -sn
			buf[o + 10] = cs
		buf[o + 3] = nx + ox
		buf[o + 11] = nz + oz
		# terrain height: bilinear over the half-metre heightfield
		var hxx := nx * 2.0
		var hzz := nz * 2.0
		var hi := int(hxx)
		var hj := int(hzz)
		var htx := hxx - hi
		var hk := hj * hgw + hi
		var h0 := hg[hk] + (hg[hk + 1] - hg[hk]) * htx
		var h1 := hg[hk + hgw] + (hg[hk + hgw + 1] - hg[hk + hgw]) * htx
		var y := h0 + (h1 - h0) * (hzz - hj)
		if burrowed:
			if pose > -3.5:
				pose = -3.0   # the shader sinks it so only the head and mound show
		elif kind[ncell] == K_STRUCT:
			y += sheight[ncell]
		else:
			y += pile[ncell] * 0.85
		buf[o + 7] = y
		var fl := buf[o + 12]
		if fl > 0.0:
			buf[o + 12] = maxf(0.0, fl - dt * 7.0)
		buf[o + 13] = -(extra + (2.0 if rg > 0.0 else 0.0))
		buf[o + 15] = pose if pose < 0.0 else minf(sqrt(sp2) / maxf(s, 0.1), 1.2)
		# stride phase follows the distance actually covered: no foot sliding
		# (backward while dragging a colonist)
		var walked := sqrt(mvx * mvx + mvz * mvz) * stride
		var g0 := gait[i]
		var gp := g0 + walked
		if carrying and drag_back:
			gp = g0 - walked
			if gp < 0.0:
				gp += 12.566371
		elif gp > 12.566371:
			gp -= 12.566371
		gait[i] = gp
		buf[o + 14] = gp
		# heavy strains shake the ground with every footfall
		if heavy > 0.0 and walked > 0.0 and int(g0 * 0.31830989) != int(gp * 0.31830989) \
				and absf(nx - lx_) < 30.0 and absf(nz - lz_) < 30.0:
			steps.append(nx + ox); steps.append(nz + oz); steps.append(heavy * sz[i])
	_c_reached[ci] = reached
	_c_core[ci] = core_dmg
