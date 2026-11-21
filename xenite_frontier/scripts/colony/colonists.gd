class_name ColonistSystem
extends Node3D
## The contracted colonists, in two roles:
##   WORKERS (orange trim) build construction sites, repair damage (paying
##   Biomass per HP), staff economy buildings and Mining Rigs, and crew
##   turrets when nothing else needs doing.
##   SOLDIERS (blue armour, rifles) crew turrets first, then garrison Guard
##   Posts and shoot from them. Select soldiers (click / drag box) and
##   right-click to send them anywhere; H returns them to their posts.
## Uncrewed turrets fire at 40%. Anyone outside - walking, building,
## repairing, holding a squad position, limping home - is exposed:
##   - Snatchers and Burrowers drag them toward the map edge (kill the carrier
##     to drop them, wounded); Snatchers also pull crews out of turrets, posts
##     and rigs.
##   - Maulers and Brood Mothers maul (HP; soldiers are armoured).
## Recruit workers at the Command Hab, train soldiers at a Barracks.
## Population cap: base + Hab Modules. Wages are paid after every wave.
## Walking uses AStarGrid2D (blast doors let colonists through, not aliens).

signal event(text: String, color: Color, pos: Vector3)

enum Role { WORKER, SOLDIER }
enum S { RESERVE, MOVING, WORKING, CARRIED, DOWNED, RETURNING, RECOVERING, DEAD, LOST }
enum Job { NONE, CREW, GARRISON, BUILD, REPAIR, STAFF, SQUAD }

class Colonist:
	var id := 0
	var name := ""
	var role := Role.WORKER
	var node: Node3D
	var pos := Vector3.ZERO
	var state := S.RESERVE
	var job := Job.NONE
	var job_cell := -1
	var hold := Vector3.ZERO      # squad hold position
	var ordered := false          # under player squad orders
	var selected := false
	var path: Array[Vector2i] = []
	var path_i := 0
	var timer := 0.0
	var wounded := false
	var last_seen := 0.0
	var smear := 0.0
	var hp := 100.0
	var max_hp := 100.0
	var immune := 0.0
	var cooldown := 0.0
	var aim := Vector3.ZERO

var map: OutpostMap
var structures: Structures
var corpses: Corpses
var fx: Fx
var economy: Economy
var combat: Combat
var hunt_field: FlowField
var colonists: Array[Colonist] = []
var astar := AStarGrid2D.new()

var walk_speed := 4.2
var uncrewed_rate := 0.4
var recovery_time := 40.0
var recovery_mult := 1.0           # Medbay / Colony Charter medics
var stun_time := 1.2
var hunt_interval := 0.6
var immunity := 1.5
var morale := 1.0                  # unpaid wages -> 0.8
var soldier_cfg: Dictionary = {}

# recruitment queue: [{role, t}]
var training: Array[Dictionary] = []

# run stats
var abductions := 0
var rescued := 0
var taken := 0
var killed := 0
var recruited := 0

var _assign_timer := 0.0
var _hunt_timer := 0.0
var _exposed_written := PackedInt32Array()
var _crew_written := PackedInt32Array()
var _mats := {}
var _rng := RandomNumberGenerator.new()
var _last_goals := PackedInt32Array()
var _names: Array = []
var _name_i := 0


func setup(m: OutpostMap, st: Structures, c: Corpses, effects: Fx, hf: FlowField, econ: Economy) -> void:
	map = m
	structures = st
	corpses = c
	fx = effects
	hunt_field = hf
	economy = econ
	var cfg := GameConfig.colonists
	hunt_field.max_dist = int(float(cfg.get("hunt_sense_range", 14.0)) * 1.5 * FlowField.ORTHO)
	walk_speed = float(cfg.get("walk_speed", walk_speed))
	uncrewed_rate = float(cfg.get("uncrewed_fire_rate", uncrewed_rate))
	recovery_time = float(cfg.get("rescued_recovery_seconds", recovery_time))
	stun_time = float(cfg.get("drop_stun_seconds", stun_time))
	hunt_interval = float(cfg.get("hunt_field_interval", hunt_interval))
	immunity = float(cfg.get("grab_immunity_seconds", immunity))
	soldier_cfg = cfg.get("soldier", {})
	_mats = {
		"white": TurretModels.mat(Color(0.88, 0.88, 0.86), 0.0, 0.15),
		"orange": TurretModels.mat(Color(0.95, 0.45, 0.08), 0.0, 0.1),
		"armor": TurretModels.mat(Color(0.25, 0.33, 0.48), 0.0, 0.45),
		"gold": TurretModels.mat(Color(1.0, 0.72, 0.25), 0.6, 0.9),
		"red": TurretModels.mat(Color(1.0, 0.25, 0.2), 1.2, 0.3),
		"dark": TurretModels.mat(Color(0.18, 0.19, 0.2), 0.0, 0.4),
		"ring": TurretModels.mat(Color(0.3, 1.0, 0.5), 1.5, 0.0),
	}
	astar.region = Rect2i(0, 0, map.w, map.h)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()


func _walkable(c: int) -> bool:
	var k := map.kind[c]
	if k == OutpostMap.Kind.ROCK:
		return false
	if k == OutpostMap.Kind.STRUCT:
		return map.stype[c] == OutpostMap.SType.DOOR and not structures.is_site(c)
	return true


func refresh_cell(c: int) -> void:
	astar.set_point_solid(Vector2i(c % map.w, c / map.w), not _walkable(c))


func _rebuild_astar() -> void:
	for c in map.kind.size():
		astar.set_point_solid(Vector2i(c % map.w, c / map.w), not _walkable(c))


func reset() -> void:
	for col in colonists:
		if col.node:
			col.node.queue_free()
	colonists.clear()
	training.clear()
	abductions = 0
	rescued = 0
	taken = 0
	killed = 0
	recruited = 0
	morale = 1.0
	_last_goals = PackedInt32Array([-1])
	_rebuild_astar()
	_names = GameConfig.colonists.get("names", ["Colonist"]).duplicate()
	_names.shuffle()
	_name_i = 0
	for t: Turret in structures.turrets.values():
		t.crewed = false


## Starting crew once the outpost has landed.
func spawn_starting_crew() -> void:
	var pop := GameConfig.econ("population")
	for k in int(pop.get("starting_workers", 6)):
		_spawn(Role.WORKER, map.core_center)
	for k in int(pop.get("starting_soldiers", 4)):
		_spawn(Role.SOLDIER, map.core_center)


func _spawn(role: int, at: Vector3) -> Colonist:
	var c := Colonist.new()
	c.id = colonists.size()
	c.role = role
	var ranks: Array = ["Pvt.", "Cpl.", "Sgt."] if role == Role.SOLDIER else GameConfig.colonists.get("ranks", ["Tech"])
	c.name = "%s %s" % [ranks[_rng.randi() % ranks.size()], _names[_name_i % _names.size()]]
	_name_i += 1
	c.max_hp = float(soldier_cfg.get("hp", 130.0)) if role == Role.SOLDIER else float(GameConfig.colonists.get("worker_hp", 100.0))
	c.hp = c.max_hp
	c.node = _make_node(role)
	c.node.visible = false
	c.pos = at
	add_child(c.node)
	colonists.append(c)
	return c


# ------------------------------------------------------------ visuals

func _make_node(role: int) -> Node3D:
	var n := Node3D.new()
	var suit: StandardMaterial3D = _mats.white
	var trim: StandardMaterial3D = _mats.orange
	if role == Role.SOLDIER:
		trim = _mats.armor
	TurretModels.part(n, MeshAcc.capsule(0.17, 0.5, 8, 2), suit, Vector3(0, 0.72, 0))
	TurretModels.part(n, MeshAcc.box(0.36, 0.1 if role == Role.WORKER else 0.3, 0.24 if role == Role.WORKER else 0.28), trim, Vector3(0, 0.9 if role == Role.WORKER else 0.8, 0))
	TurretModels.part(n, MeshAcc.box(0.3, 0.38, 0.16), suit if role == Role.WORKER else trim, Vector3(0, 0.78, -0.17))
	for sx in [-0.09, 0.09]:
		TurretModels.part(n, MeshAcc.cyl(0.05, 0.3, -1.0, 6), trim, Vector3(sx, 0.8, -0.26))
	TurretModels.part(n, MeshAcc.ball(0.17, 10, 6), suit if role == Role.WORKER else trim, Vector3(0, 1.12, 0))
	TurretModels.part(n, MeshAcc.box(0.22, 0.12 if role == Role.WORKER else 0.07, 0.08), _mats.gold if role == Role.WORKER else _mats.red, Vector3(0, 1.13, 0.13))
	for side: float in [-1.0, 1.0]:
		var leg := Node3D.new()
		leg.name = "LegL" if side < 0 else "LegR"
		leg.position = Vector3(side * 0.09, 0.5, 0)
		n.add_child(leg)
		TurretModels.part(leg, MeshAcc.capsule(0.075, 0.46, 6, 1), suit, Vector3(0, -0.22, 0))
		TurretModels.part(leg, MeshAcc.box(0.12, 0.08, 0.2), _mats.dark, Vector3(0, -0.46, 0.03))
		TurretModels.part(leg, MeshAcc.box(0.13, 0.06, 0.13), trim, Vector3(0, -0.24, 0.02))
		var arm := Node3D.new()
		arm.name = "ArmL" if side < 0 else "ArmR"
		arm.position = Vector3(side * 0.23, 0.9, 0)
		n.add_child(arm)
		TurretModels.part(arm, MeshAcc.capsule(0.06, 0.42, 6, 1), suit if role == Role.WORKER else trim, Vector3(0, -0.18, 0))
		TurretModels.part(arm, MeshAcc.ball(0.06, 6, 3), _mats.dark, Vector3(0, -0.4, 0))
	if role == Role.SOLDIER:
		# rifle held across the body + shoulder pads
		TurretModels.part(n, MeshAcc.box(0.06, 0.08, 0.62), _mats.dark, Vector3(0.12, 0.78, 0.22))
		for sx in [-0.21, 0.21]:
			TurretModels.part(n, MeshAcc.box(0.14, 0.08, 0.2), trim, Vector3(sx, 0.98, 0))
	else:
		# tool belt
		TurretModels.part(n, MeshAcc.box(0.38, 0.06, 0.26), _mats.dark, Vector3(0, 0.55, 0))
	var ring := TurretModels.part(n, MeshAcc.cyl(0.42, 0.02, -1.0, 16), _mats.ring, Vector3(0, 0.03, 0))
	ring.name = "Ring"
	ring.visible = false
	return n


func _animate(col: Colonist, walking: bool, working: bool) -> void:
	var t := Time.get_ticks_msec() * 0.011 + col.id * 1.7
	var amp := 0.6 if walking else 0.0
	if col.wounded and walking:
		amp = 0.35
	var sw := sin(t) * amp
	col.node.get_node("LegL").rotation.x = sw
	col.node.get_node("LegR").rotation.x = -sw
	if working:
		# hammering / welding motion
		col.node.get_node("ArmR").rotation.x = -1.2 + sin(t * 1.6) * 0.5
		col.node.get_node("ArmL").rotation.x = -0.6
	else:
		col.node.get_node("ArmL").rotation.x = -sw * 0.8
		col.node.get_node("ArmR").rotation.x = sw * 0.8


# ------------------------------------------------------------ counts

func count_state(s: int) -> int:
	var n := 0
	for c in colonists:
		if c.state == s:
			n += 1
	return n


func count_role(role: int) -> int:
	var n := 0
	for c in colonists:
		if c.role == role and c.state != S.DEAD and c.state != S.LOST:
			n += 1
	return n


func count_job(role: int, job: int) -> int:
	var n := 0
	for c in colonists:
		if c.role == role and c.job == job and c.state == S.WORKING:
			n += 1
	return n


func alive() -> int:
	var n := 0
	for c in colonists:
		if c.state != S.DEAD and c.state != S.LOST:
			n += 1
	return n


func pop_cap() -> int:
	var pop := GameConfig.econ("population")
	return int(pop.get("base_cap", 12)) + int(pop.get("per_hab_module", 4)) * structures.count_built("hab_module")


func wages_due() -> int:
	var w := GameConfig.econ("wages_per_wave")
	return count_role(Role.WORKER) * int(w.get("worker", 3)) + count_role(Role.SOLDIER) * int(w.get("soldier", 5))


func crew_name(cell: int) -> String:
	for c in colonists:
		if c.job_cell == cell and c.job != Job.NONE and c.state in [S.MOVING, S.WORKING]:
			return c.name + ("" if c.state == S.WORKING else " (on the way)")
	return ""


func names_at(cell: int, job: int) -> PackedStringArray:
	var out: PackedStringArray = []
	for c in colonists:
		if c.job_cell == cell and c.job == job and c.state in [S.MOVING, S.WORKING]:
			out.append(c.name + ("" if c.state == S.WORKING else " (en route)"))
	return out


# ------------------------------------------------------------ recruitment

## Queue a new colonist. Returns "" or why not.
func recruit(role: int) -> String:
	var key := "soldier" if role == Role.SOLDIER else "worker"
	var rc: Dictionary = GameConfig.econ("recruit").get(key, {})
	if role == Role.SOLDIER and structures.count_built("barracks") == 0:
		return "Build a Barracks to train soldiers"
	if alive() + training.size() >= pop_cap():
		return "Colony full (%d) - build a Hab Module" % pop_cap()
	var cost := int(rc.get("cost", 50))
	if not economy.can_afford(cost):
		return "Need %d Biomass" % cost
	economy.spend(cost)
	training.append({"role": role, "t": float(rc.get("seconds", 8.0))})
	return ""


func _tick_training(dt: float) -> void:
	var k := 0
	while k < training.size():
		training[k].t -= dt
		if training[k].t <= 0.0:
			var role: int = training[k].role
			var at := map.core_center
			if role == Role.SOLDIER:
				var b := structures.cells_of("barracks")
				if not b.is_empty():
					at = map.cell_ground(b[0])
			var c := _spawn(role, at)
			recruited += 1
			event.emit("%s reports for duty" % c.name, Color(0.6, 0.9, 1.0), at)
			training.remove_at(k)
		else:
			k += 1


# ------------------------------------------------------------ structures

func on_structure_built(c: int, _id: String) -> void:
	refresh_cell(c)


func on_structure_removed(c: int, _id: String) -> void:
	refresh_cell(c)
	for col in colonists:
		if col.job_cell != c:
			continue
		var inside := col.state == S.WORKING and col.job in [Job.CREW, Job.GARRISON, Job.STAFF]
		_clear_job(col)
		if inside:
			# the structure is gone: whoever was in it bails out, exposed
			col.state = S.DOWNED
			col.timer = stun_time
			col.pos = map.cell_ground(c)
			col.node.visible = true
		elif col.state == S.MOVING or col.state == S.WORKING:
			_go_idle(col)


# ------------------------------------------------------------ squad orders

func soldier_at(p: Vector3, radius := 0.9) -> Colonist:
	var best: Colonist = null
	var bd := radius
	for c in colonists:
		if c.role == Role.SOLDIER and c.node.visible and c.state in [S.MOVING, S.WORKING, S.RETURNING]:
			var d := Vector2(c.pos.x - p.x, c.pos.z - p.z).length()
			if d < bd:
				bd = d
				best = c
	return best


func select_none() -> void:
	for c in colonists:
		c.selected = false
		c.node.get_node("Ring").visible = false


func set_selected(c: Colonist, on: bool) -> void:
	c.selected = on
	c.node.get_node("Ring").visible = on


func selected_count() -> int:
	var n := 0
	for c in colonists:
		if c.selected:
			n += 1
	return n


## Soldiers whose screen position is inside `rect`.
func select_in_rect(rect: Rect2, cam: Camera3D) -> void:
	for c in colonists:
		if c.role != Role.SOLDIER or c.state in [S.DEAD, S.LOST, S.CARRIED, S.RECOVERING]:
			continue
		var p := c.pos if c.node.visible else map.core_center
		if cam.is_position_behind(p):
			continue
		if rect.has_point(cam.unproject_position(p + Vector3(0, 0.8, 0))):
			set_selected(c, true)


## Send the selected soldiers to hold around `target` (they leave turrets
## and posts - those lose their crew until released with H).
func order_move(target: Vector3) -> int:
	var sel: Array[Colonist] = []
	for c in colonists:
		if c.selected and c.state not in [S.DEAD, S.LOST, S.CARRIED]:
			sel.append(c)
	for k in sel.size():
		var c := sel[k]
		var ang := TAU * k / maxf(1, sel.size())
		var off := Vector3(cos(ang), 0, sin(ang)) * (0.0 if sel.size() == 1 else 0.9 + 0.25 * sel.size())
		_clear_job(c)
		c.ordered = true
		c.job = Job.SQUAD
		c.hold = target + off
		if c.state == S.RESERVE or c.state == S.RECOVERING:
			c.pos = map.core_center
		c.state = S.MOVING
		c.node.visible = true
		_plan_path(c, map.world_to_cell(c.hold))
	return sel.size()


## Return selected (or all ordered) soldiers to automatic duty.
func release_orders(all := false) -> void:
	for c in colonists:
		if c.ordered and (all or c.selected):
			c.ordered = false
			_clear_job(c)
			_go_idle(c)


# ------------------------------------------------------------ swarm events

## Called after the swarm step, before deaths are flushed (handles valid).
func process_swarm(swarm: Swarm, comb: Combat) -> void:
	var g := swarm.out_grab
	for k in range(0, g.size(), 3):
		var h := g[k]
		var cid := g[k + 1]
		if cid < 0 or cid >= colonists.size():
			continue
		var col := colonists[cid]
		var inside := col.state == S.WORKING and col.job in [Job.CREW, Job.GARRISON, Job.STAFF]
		var exposed := _is_exposed(col)
		if (not exposed and not inside) or col.immune > 0.0:
			continue
		var p := swarm.pools[h >> Swarm.SHIFT]
		var i := h & Swarm.MASK
		if i >= p.count or p.hp[i] <= 0.0 or p.carry[i] >= 0:
			continue
		if g[k + 2] == 1:
			if inside:
				continue  # maulers can't reach into a structure
			var dmg := float(p.def.get("maul_damage", 100.0)) * (float(soldier_cfg.get("armor", 0.7)) if col.role == Role.SOLDIER else 1.0)
			col.hp -= dmg
			fx.burst(col.pos + Vector3(0, 0.6, 0), Color(0.6, 0.02, 0.02, 0.1), 8, 3.0, 0.08, 0.6, 1.0)
			if col.hp > 0.0:
				_clear_job(col)
				col.ordered = false
				col.state = S.DOWNED
				col.wounded = true
				col.timer = stun_time
				col.immune = immunity
				event.emit("%s was mauled by a %s - wounded" % [col.name, p.def.name], Color(1.0, 0.6, 0.3), col.pos)
				continue
			_clear_job(col)
			col.state = S.DEAD
			killed += 1
			col.node.visible = false
			corpses.add_human(col.pos)
			fx.burst(col.pos + Vector3(0, 0.6, 0), Color(0.6, 0.02, 0.02, 0.1), 14, 4.0, 0.1, 0.8, 1.0)
			event.emit("%s was mauled to death by a %s" % [col.name, p.def.name], Color(1.0, 0.3, 0.25), col.pos)
			continue
		var how := "pulled from their post" if inside else "seized"
		if inside:
			col.pos = map.cell_ground(col.job_cell)
		_clear_job(col)
		col.ordered = false
		p.carry[i] = cid
		col.state = S.CARRIED
		col.last_seen = 0.0
		col.node.visible = true
		abductions += 1
		event.emit("%s %s by a %s!" % [col.name, how, p.def.name], Color(1.0, 0.55, 0.2), col.pos)
	var cp := swarm.out_carried
	for k in range(0, cp.size(), 3):
		var col := colonists[int(cp[k])]
		if col.state != S.CARRIED:
			continue
		var np := Vector3(cp[k + 1], 0.0, cp[k + 2])
		var d := np - col.pos
		d.y = 0.0
		if d.length_squared() > 0.0001:
			col.node.rotation = Vector3(-PI * 0.5, atan2(-d.x, -d.z), 0.0)
		col.pos = np
		col.last_seen = 0.0
	var e := swarm.out_escape
	for k in range(0, e.size(), 2):
		var col := colonists[e[k + 1]]
		if col.state != S.CARRIED:
			continue
		col.state = S.LOST
		col.node.visible = false
		taken += 1
		comb.despawn(e[k])
		event.emit("%s was dragged into the wilds. Gone." % col.name, Color(1.0, 0.25, 0.25), col.pos)


## Carrier died: the colonist drops, wounded.
func drop(cid: int, pos: Vector3) -> void:
	if cid < 0 or cid >= colonists.size():
		return
	var col := colonists[cid]
	if col.state != S.CARRIED:
		return
	col.state = S.DOWNED
	col.wounded = true
	col.timer = stun_time
	col.pos = Vector3(pos.x, 0.0, pos.z)
	col.immune = immunity
	rescued += 1
	event.emit("%s rescued! Wounded, heading home." % col.name, Color(0.5, 1.0, 0.45), col.pos)


# ------------------------------------------------------------ tick

func tick(dt: float) -> void:
	recovery_mult = 0.5 if structures.count_active("medbay") > 0 else 1.0
	_tick_training(dt)
	_assign_timer -= dt
	if _assign_timer <= 0.0:
		_assign_timer = 0.5
		_assign()
	for col in colonists:
		_tick_colonist(col, dt)
	_write_grids()
	var staffed := {}
	for col in colonists:
		if col.state == S.WORKING and col.job == Job.STAFF:
			staffed[col.job_cell] = col.id
	structures.staff = staffed
	for cell: int in structures.turrets:
		var t: Turret = structures.turrets[cell]
		t.crewed = false
		t.uncrewed_rate = uncrewed_rate * morale
		t.morale = morale
	for col in colonists:
		if col.state == S.WORKING and col.job == Job.CREW and structures.turrets.has(col.job_cell):
			structures.turrets[col.job_cell].crewed = true
	_hunt_timer -= dt
	if _hunt_timer <= 0.0:
		_hunt_timer = hunt_interval
		var goals := PackedInt32Array()
		for col in colonists:
			if _is_exposed(col):
				var c := map.cell_of(col.pos)
				if c >= 0:
					goals.append(c)
			elif col.state == S.WORKING and col.job in [Job.CREW, Job.GARRISON, Job.STAFF]:
				goals.append(col.job_cell)
		goals.sort()
		if goals != _last_goals:
			_last_goals = goals
			hunt_field.set_goals(goals)
			hunt_field.request_rebuild()


func _is_exposed(col: Colonist) -> bool:
	match col.state:
		S.MOVING, S.DOWNED, S.RETURNING:
			return true
		S.WORKING:
			return col.job in [Job.BUILD, Job.REPAIR, Job.SQUAD]
	return false


func _available(col: Colonist) -> bool:
	return not col.ordered and not col.wounded and (col.state == S.RESERVE or (col.state == S.RETURNING and col.job == Job.NONE))


func _count_on(cell: int, job: int) -> int:
	var n := 0
	for c in colonists:
		if c.job_cell == cell and c.job == job and c.state in [S.MOVING, S.WORKING]:
			n += 1
	return n


func _nearest_available(role: int, to: Vector3) -> Colonist:
	var best: Colonist = null
	var bd := INF
	for c in colonists:
		if c.role != role or not _available(c):
			continue
		var from := c.pos if c.state == S.RETURNING else map.core_center
		var d := from.distance_squared_to(to)
		if d < bd:
			bd = d
			best = c
	return best


## Job assignment (every 0.5 s).
func _assign() -> void:
	# turrets: soldiers first, then idle workers; most valuable first
	var turret_cells: Array = structures.turrets.keys()
	turret_cells.sort_custom(func(a, b):
		return GameConfig.build_cost(structures.ids[a]) * structures.tier_at(a) > GameConfig.build_cost(structures.ids[b]) * structures.tier_at(b))
	for cell: int in turret_cells:
		if _count_on(cell, Job.CREW) == 0:
			var c := _nearest_available(Role.SOLDIER, map.cell_center(cell))
			if c:
				_give_job(c, Job.CREW, cell)
	# guard posts
	for cell in structures.cells_of("guard_post"):
		if structures.is_site(cell):
			continue
		var slots := int(structures.defs["guard_post"].get("garrison", 2))
		while _count_on(cell, Job.GARRISON) < slots:
			var c := _nearest_available(Role.SOLDIER, map.cell_center(cell))
			if c == null:
				break
			_give_job(c, Job.GARRISON, cell)
	# workers: build, repair, staff, then crew leftover turrets
	for cell: int in structures.sites:
		while _count_on(cell, Job.BUILD) < 2:
			var c := _nearest_available(Role.WORKER, map.cell_center(cell))
			if c == null:
				c = _pull_worker_from(Job.CREW)
			if c == null:
				break
			_give_job(c, Job.BUILD, cell)
	if economy.biomass >= 5.0:
		for cell: int in structures.ids:
			if structures.is_site(cell) or _count_on(cell, Job.REPAIR) > 0:
				continue
			if map.shp[cell] < map.smax[cell] * 0.7:
				var c := _nearest_available(Role.WORKER, map.cell_center(cell))
				if c == null:
					break
				_give_job(c, Job.REPAIR, cell)
	for cell: int in structures.ids:
		if structures.is_site(cell) or int(structures.defs[structures.ids[cell]].get("staff", 0)) == 0:
			continue
		if _count_on(cell, Job.STAFF) == 0:
			var c := _nearest_available(Role.WORKER, map.cell_center(cell))
			if c == null:
				c = _pull_worker_from(Job.CREW)
			if c:
				_give_job(c, Job.STAFF, cell)
	for cell: int in turret_cells:
		if _count_on(cell, Job.CREW) == 0:
			var c := _nearest_available(Role.WORKER, map.cell_center(cell))
			if c:
				_give_job(c, Job.CREW, cell)


## Workers crewing turrets are the first to be re-tasked to building/staffing.
func _pull_worker_from(job: int) -> Colonist:
	for c in colonists:
		if c.role == Role.WORKER and c.job == job and c.state in [S.MOVING, S.WORKING] and not c.wounded:
			_clear_job(c)
			c.pos = map.cell_ground(c.job_cell) if c.job_cell >= 0 else c.pos
			c.state = S.RETURNING
			return c
	return null


func _give_job(c: Colonist, job: int, cell: int) -> void:
	if c.state == S.RESERVE:
		c.pos = map.core_center
	c.job = job
	c.job_cell = cell
	c.state = S.MOVING
	c.node.visible = true
	c.node.rotation = Vector3.ZERO
	_plan_path(c, _adjacent_free(cell, c.pos))


func _clear_job(c: Colonist) -> void:
	c.job = Job.NONE
	c.job_cell = -1


## Done with a job outside: walk home, but available for the next one.
func _go_idle(c: Colonist) -> void:
	_clear_job(c)
	c.state = S.RETURNING
	c.node.visible = true
	_plan_path(c, map.world_to_cell(map.core_center))


func _adjacent_free(cell: int, from: Vector3) -> Vector2i:
	var cx := cell % map.w
	var cz := cell / map.w
	var best := Vector2i(cx, cz)
	var best_d := INF
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oz == 0:
				continue
			var x := cx + ox
			var z := cz + oz
			if not map.in_bounds(x, z) or not _walkable(map.idx(x, z)):
				continue
			var d := Vector2(x + map.origin.x, z + map.origin.y).distance_squared_to(Vector2(from.x, from.z))
			if d < best_d:
				best_d = d
				best = Vector2i(x, z)
	return best


func _nearest_walkable(v: Vector2i) -> Vector2i:
	if map.in_bounds(v.x, v.y) and _walkable(map.idx(v.x, v.y)):
		return v
	for r in range(1, 5):
		for oz in range(-r, r + 1):
			for ox in range(-r, r + 1):
				var x := v.x + ox
				var z := v.y + oz
				if map.in_bounds(x, z) and _walkable(map.idx(x, z)):
					return Vector2i(x, z)
	return v


func _plan_path(col: Colonist, to: Vector2i) -> void:
	var from := _nearest_walkable(map.world_to_cell(col.pos))
	to = _nearest_walkable(to)
	col.path = astar.get_id_path(from, to)
	col.path_i = 0


func _blocked_ahead(col: Colonist) -> bool:
	return col.path_i < col.path.size() and not _walkable(map.idx(col.path[col.path_i].x, col.path[col.path_i].y))


## Walks along the path; returns true on arrival.
func _walk(col: Colonist, dt: float) -> bool:
	if col.path_i >= col.path.size():
		return true
	var step := walk_speed * dt * (0.6 if col.wounded else 1.0)
	while step > 0.0 and col.path_i < col.path.size():
		var cellv := col.path[col.path_i]
		if not _walkable(map.idx(cellv.x, cellv.y)):
			return false
		var target := Vector3(cellv.x + map.origin.x + 0.5, 0.0, cellv.y + map.origin.y + 0.5)
		var d := target - col.pos
		d.y = 0.0
		var l := d.length()
		if l <= step:
			col.pos = Vector3(target.x, col.pos.y, target.z)
			step -= l
			col.path_i += 1
		else:
			col.pos += d / l * step
			col.node.rotation.y = atan2(d.x, d.z)
			step = 0.0
	return col.path_i >= col.path.size()


func _job_target_ok(col: Colonist) -> bool:
	match col.job:
		Job.CREW:
			return structures.turrets.has(col.job_cell)
		Job.GARRISON, Job.STAFF:
			return structures.ids.has(col.job_cell) and not structures.is_site(col.job_cell)
		Job.BUILD:
			return structures.is_site(col.job_cell)
		Job.REPAIR:
			return structures.ids.has(col.job_cell) and not structures.is_site(col.job_cell) and map.shp[col.job_cell] < map.smax[col.job_cell]
		Job.SQUAD:
			return true
	return false


func _tick_colonist(col: Colonist, dt: float) -> void:
	if col.immune > 0.0:
		col.immune -= dt
	var working_anim := false
	match col.state:
		S.MOVING:
			if not _job_target_ok(col):
				_go_idle(col)
				return
			var arrived := _walk(col, dt)
			if col.path.is_empty() or (not arrived and _blocked_ahead(col)):
				var dest := map.world_to_cell(col.hold) if col.job == Job.SQUAD else _adjacent_free(col.job_cell, col.pos)
				_plan_path(col, dest)
				if col.path.is_empty():
					event.emit("%s can't get there - build a Blast Door" % col.name, Color(1.0, 0.8, 0.3), col.pos)
					col.ordered = false
					_go_idle(col)
				return
			if arrived:
				col.state = S.WORKING
				col.node.rotation = Vector3.ZERO
				if col.job == Job.STAFF:
					col.node.visible = false
		S.WORKING:
			if not _job_target_ok(col):
				_go_idle(col)
				return
			match col.job:
				Job.CREW:
					col.pos = map.cell_ground(col.job_cell) + Vector3(0, 1.05, -0.28)
				Job.GARRISON:
					var slot := 0
					for o in colonists:
						if o == col:
							break
						if o.job == Job.GARRISON and o.job_cell == col.job_cell and o.state == S.WORKING:
							slot += 1
					col.pos = map.cell_ground(col.job_cell) + Vector3(-0.22 + slot * 0.44, 2.28, 0)
				Job.STAFF:
					col.pos = map.cell_ground(col.job_cell)
				Job.BUILD:
					working_anim = true
					_face(col, map.cell_center(col.job_cell))
					var rate := float(GameConfig.econ("construction").get("work_rate", 1.0))
					if structures.work_on(col.job_cell, rate * dt):
						event.emit("%s finished the %s" % [col.name, structures.defs[structures.ids[col.job_cell]].name], Color(0.6, 0.9, 1.0), col.pos)
						_go_idle(col)
						return
				Job.REPAIR:
					working_anim = true
					_face(col, map.cell_center(col.job_cell))
					var hp := float(GameConfig.econ("repair").get("hp_per_second", 30.0)) * dt
					hp = minf(hp, map.smax[col.job_cell] - map.shp[col.job_cell])
					var cost := hp * economy.repair_per_hp
					if economy.biomass < cost:
						_go_idle(col)
						return
					economy.pay(cost, "repair")
					economy.wages_paid -= cost  # repairs are not wages
					economy.spent += cost
					map.shp[col.job_cell] += hp
					structures._visual_dirty = true
					if map.shp[col.job_cell] >= map.smax[col.job_cell]:
						_go_idle(col)
						return
		S.DOWNED:
			col.node.rotation = Vector3(-PI * 0.5, col.node.rotation.y, 0.0)
			col.timer -= dt
			if col.timer <= 0.0:
				col.node.rotation = Vector3.ZERO
				_go_idle(col)
		S.RETURNING:
			var arrived := _walk(col, dt)
			if col.path.is_empty() or (not arrived and _blocked_ahead(col)):
				_plan_path(col, map.world_to_cell(map.core_center))
			if arrived or col.pos.distance_to(map.core_center) < 1.6:
				col.node.visible = false
				col.node.rotation = Vector3.ZERO
				if col.wounded:
					col.state = S.RECOVERING
					col.timer = recovery_time * recovery_mult
				else:
					col.state = S.RESERVE
		S.RECOVERING:
			col.timer -= dt
			if col.timer <= 0.0:
				col.wounded = false
				col.hp = col.max_hp
				col.state = S.RESERVE
				event.emit("%s is back on duty" % col.name, Color(0.6, 0.9, 1.0), map.core_center)
		S.RESERVE:
			if structures.count_active("medbay") > 0:
				col.hp = minf(col.max_hp, col.hp + 5.0 * dt)
		S.CARRIED:
			col.last_seen += dt
			col.smear -= dt
			if col.smear <= 0.0:
				col.smear = 0.35
				fx.splat(Vector3(col.pos.x, 0.0, col.pos.z), Color(0.75, 0.05, 0.05), 0.22)
			if col.last_seen > 1.0:
				drop(col.id, col.pos)
	if col.role == Role.SOLDIER and combat:
		_soldier_fire(col, dt)
	if col.node.visible:
		var walking := col.state == S.MOVING or col.state == S.RETURNING
		var p := col.pos
		if not (col.state == S.WORKING and col.job in [Job.CREW, Job.GARRISON]):
			p.y = map.height_at(p.x, p.z) + (0.3 if col.state == S.CARRIED else 0.0)
		col.node.position = p
		_animate(col, walking, working_anim)


func _face(col: Colonist, at: Vector3) -> void:
	var d := at - col.pos
	if Vector2(d.x, d.z).length_squared() > 0.001:
		col.node.rotation.y = atan2(d.x, d.z)


## Rifle fire: soldiers shoot from posts, squad positions and on the move.
func _soldier_fire(col: Colonist, dt: float) -> void:
	col.cooldown -= dt
	if col.cooldown > 0.0:
		return
	var firing := (col.state == S.WORKING and col.job in [Job.GARRISON, Job.SQUAD]) or col.state == S.MOVING or (col.state == S.RETURNING and not col.wounded)
	if not firing:
		return
	var rng := float(soldier_cfg.get("range", 9.0))
	if col.job == Job.GARRISON and col.state == S.WORKING:
		rng += float(structures.defs.get("guard_post", {}).get("range_bonus", 4.0))
	var h := combat.find_target(col.pos.x, col.pos.z, rng, 0.0)
	if h < 0:
		col.cooldown = 0.25
		return
	col.cooldown = 1.0 / (float(soldier_cfg.get("fire_rate", 2.2)) * morale)
	var tp := combat.pos_of(h)
	tp.y = map.height_at(tp.x, tp.z) + 0.6
	_face(col, tp)
	var dmg := float(soldier_cfg.get("damage", 7.0)) * (1.0 + (float(structures.defs.get("armory", {}).get("soldier_damage_bonus", 0.25)) if structures.count_active("armory") > 0 else 0.0))
	var muzzle := col.node.position + Vector3(0, 0.85, 0)
	fx.beam(muzzle, tp, Color(1.0, 0.85, 0.45, 0.9), 0.035, 0.05)
	combat.damage(h, dmg, GameConfig.Dmg.BALLISTIC, true)


func _write_grids() -> void:
	for c in _exposed_written:
		map.colonist_at[c] = 0
	for c in _crew_written:
		map.crew_at[c] = 0
	_exposed_written.clear()
	_crew_written.clear()
	for col in colonists:
		if _is_exposed(col):
			var c := map.cell_of(col.pos)
			if c >= 0:
				map.colonist_at[c] = col.id + 1
				_exposed_written.append(c)
		elif col.state == S.WORKING and col.job in [Job.CREW, Job.GARRISON, Job.STAFF]:
			map.crew_at[col.job_cell] = col.id + 1
			_crew_written.append(col.job_cell)
