class_name ColonistSystem
extends Node3D
## The contracted colonists. They shelter in the core and walk out to crew
## turrets (uncrewed turrets fire at 40%). Anyone outside - walking to a post,
## stunned after a rescue, limping home - is exposed:
##   - abductors (Stalkers, Snatchers, Burrowers) grab them and drag them toward
##     the map edge. Kill the carrier and the colonist drops, wounded, and
##     limps back to the core to recover. Reach the edge and they are gone.
##   - Snatchers hunt colonists on a dedicated flow field and even rip crews
##     out of their turrets.
##   - maulers (Maulers, Brood Mothers) kill outright, leaving remains the
##     swarm will eat.
## Walking uses AStarGrid2D (blast doors let colonists through, not aliens).

signal event(text: String, color: Color, pos: Vector3)

enum S { RESERVE, MOVING, CREWING, CARRIED, DOWNED, RETURNING, RECOVERING, DEAD, LOST }
const STATE_NAMES := ["reserve", "moving", "crewing", "carried", "downed", "returning", "recovering", "dead", "lost"]

class Colonist:
	var id := 0
	var name := ""
	var node: Node3D
	var pos := Vector3.ZERO
	var state := S.RESERVE
	var post := -1               # turret cell this colonist crews / walks to
	var path: Array[Vector2i] = []
	var path_i := 0
	var timer := 0.0
	var wounded := false
	var last_seen := 0.0         # carried: time since last carrier update
	var smear := 0.0
	var hp := 100.0
	var immune := 0.0            # seconds of grab immunity

var map: OutpostMap
var structures: Structures
var corpses: Corpses
var fx: Fx
var hunt_field: FlowField
var colonists: Array[Colonist] = []
var astar := AStarGrid2D.new()
var crew_of := {}                 # turret cell -> colonist id

var walk_speed := 4.2
var uncrewed_rate := 0.4
var recovery_time := 40.0
var recovery_mult := 1.0           # Colony Charter medics (M6)
var stun_time := 1.2
var hunt_interval := 0.6
var max_hp := 100.0
var immunity := 1.5

# run stats
var abductions := 0
var rescued := 0
var taken := 0
var killed := 0

var _assign_timer := 0.0
var _hunt_timer := 0.0
var _exposed_written := PackedInt32Array()
var _crew_written := PackedInt32Array()
var _suit: StandardMaterial3D
var _helmet: StandardMaterial3D
var _visor: StandardMaterial3D
var _rng := RandomNumberGenerator.new()
var _last_goals := PackedInt32Array()


func setup(m: OutpostMap, st: Structures, c: Corpses, effects: Fx, hf: FlowField) -> void:
	map = m
	structures = st
	corpses = c
	fx = effects
	hunt_field = hf
	hunt_field.max_dist = int(float(GameConfig.colonists.get("hunt_sense_range", 14.0)) * 1.5 * FlowField.ORTHO)
	var cfg := GameConfig.colonists
	walk_speed = float(cfg.get("walk_speed", walk_speed))
	uncrewed_rate = float(cfg.get("uncrewed_fire_rate", uncrewed_rate))
	recovery_time = float(cfg.get("rescued_recovery_seconds", recovery_time))
	stun_time = float(cfg.get("drop_stun_seconds", stun_time))
	hunt_interval = float(cfg.get("hunt_field_interval", hunt_interval))
	max_hp = float(cfg.get("hp", max_hp))
	immunity = float(cfg.get("grab_immunity_seconds", immunity))
	_suit = TurretModels.mat(Color(0.95, 0.45, 0.08), 0.0, 0.1)     # orange trim
	_helmet = TurretModels.mat(Color(0.88, 0.88, 0.86), 0.0, 0.15)  # white EVA suit
	_visor = TurretModels.mat(Color(1.0, 0.72, 0.25), 0.6, 0.9)     # gold visor
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
		return map.stype[c] == OutpostMap.SType.DOOR
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
	crew_of.clear()
	_last_goals = PackedInt32Array([-1])
	abductions = 0
	rescued = 0
	taken = 0
	killed = 0
	_rebuild_astar()
	var names: Array = GameConfig.colonists.get("names", ["Colonist"])
	var ranks: Array = GameConfig.colonists.get("ranks", [""])
	var order := range(names.size())
	order.shuffle()
	var n := int(GameConfig.colonists.get("starting_crew", 8))
	for k in n:
		var c := Colonist.new()
		c.id = k
		c.name = "%s %s" % [ranks[_rng.randi() % ranks.size()], names[order[k % order.size()]]]
		c.node = _make_node()
		c.node.visible = false
		c.pos = map.core_center
		c.hp = max_hp
		add_child(c.node)
		colonists.append(c)
	for t: Turret in structures.turrets.values():
		t.crewed = false


## Space-suited colonist: white EVA suit with orange panels, bubble helmet
## with a gold visor, life-support backpack. Arms and legs hang from pivots
## so they can swing while walking.
func _make_node() -> Node3D:
	var n := Node3D.new()
	var suit := _helmet
	var trim := _suit
	var dark := TurretModels.mat(Color(0.18, 0.19, 0.2), 0.0, 0.4)
	TurretModels.part(n, MeshAcc.capsule(0.17, 0.5, 8, 2), suit, Vector3(0, 0.72, 0))                 # torso
	TurretModels.part(n, MeshAcc.box(0.36, 0.1, 0.24), trim, Vector3(0, 0.9, 0))                    # chest band
	TurretModels.part(n, MeshAcc.box(0.3, 0.38, 0.16), suit, Vector3(0, 0.78, -0.17))               # backpack
	TurretModels.part(n, MeshAcc.cyl(0.05, 0.3, -1.0, 6), trim, Vector3(0.09, 0.8, -0.26))         # oxygen tanks
	TurretModels.part(n, MeshAcc.cyl(0.05, 0.3, -1.0, 6), trim, Vector3(-0.09, 0.8, -0.26))
	TurretModels.part(n, MeshAcc.ball(0.17, 10, 6), suit, Vector3(0, 1.12, 0))                     # helmet
	TurretModels.part(n, MeshAcc.box(0.22, 0.12, 0.08), _visor, Vector3(0, 1.13, 0.13))            # visor
	for side in [-1.0, 1.0]:
		var leg := Node3D.new()
		leg.name = "LegL" if side < 0 else "LegR"
		leg.position = Vector3(side * 0.09, 0.5, 0)
		n.add_child(leg)
		TurretModels.part(leg, MeshAcc.capsule(0.075, 0.46, 6, 1), suit, Vector3(0, -0.22, 0))
		TurretModels.part(leg, MeshAcc.box(0.12, 0.08, 0.2), dark, Vector3(0, -0.46, 0.03))          # boot
		TurretModels.part(leg, MeshAcc.box(0.13, 0.06, 0.13), trim, Vector3(0, -0.24, 0.02))         # knee pad
		var arm := Node3D.new()
		arm.name = "ArmL" if side < 0 else "ArmR"
		arm.position = Vector3(side * 0.23, 0.9, 0)
		n.add_child(arm)
		TurretModels.part(arm, MeshAcc.capsule(0.06, 0.42, 6, 1), suit, Vector3(0, -0.18, 0))
		TurretModels.part(arm, MeshAcc.ball(0.06, 6, 3), dark, Vector3(0, -0.4, 0))                   # glove
	return n


## Walk cycle: legs and arms swing in opposition; still otherwise.
func _animate(col: Colonist, walking: bool, _dt: float) -> void:
	var t := Time.get_ticks_msec() * 0.011 + col.id * 1.7
	var amp := 0.6 if walking else 0.0
	if col.wounded and walking:
		amp = 0.35
	var sw := sin(t) * amp
	col.node.get_node("LegL").rotation.x = sw
	col.node.get_node("LegR").rotation.x = -sw
	col.node.get_node("ArmL").rotation.x = -sw * 0.8
	col.node.get_node("ArmR").rotation.x = sw * 0.8


# ------------------------------------------------------------ counts

func count_state(s: int) -> int:
	var n := 0
	for c in colonists:
		if c.state == s:
			n += 1
	return n


func alive() -> int:
	var n := 0
	for c in colonists:
		if c.state != S.DEAD and c.state != S.LOST:
			n += 1
	return n


func crew_name(turret_cell: int) -> String:
	if crew_of.has(turret_cell):
		var c := colonists[crew_of[turret_cell]]
		if c.state == S.CREWING:
			return c.name
		return c.name + " (on the way)"
	return ""


# ------------------------------------------------------------ structures

func on_structure_built(c: int, _id: String) -> void:
	refresh_cell(c)


func on_structure_removed(c: int, _id: String) -> void:
	refresh_cell(c)
	if crew_of.has(c):
		var col := colonists[crew_of[c]]
		crew_of.erase(c)
		col.post = -1
		if col.state == S.CREWING:
			# turret gone: the crew bails out, exposed
			col.state = S.DOWNED
			col.timer = stun_time
			col.pos = map.cell_ground(c)
		elif col.state == S.MOVING:
			_send_home(col)


# ------------------------------------------------------------ swarm events

## Called after the swarm step, before deaths are flushed (handles valid).
func process_swarm(swarm: Swarm, combat: Combat) -> void:
	var g := swarm.out_grab
	for k in range(0, g.size(), 3):
		var h := g[k]
		var cid := g[k + 1]
		if cid < 0 or cid >= colonists.size():
			continue
		var col := colonists[cid]
		var exposed := col.state == S.MOVING or col.state == S.DOWNED or col.state == S.RETURNING
		var crew_pull := col.state == S.CREWING
		if (not exposed and not crew_pull) or col.immune > 0.0:
			continue
		var p := swarm.pools[h >> Swarm.SHIFT]
		var i := h & Swarm.MASK
		if i >= p.count or p.hp[i] <= 0.0 or p.carry[i] >= 0:
			continue
		if g[k + 2] == 1 and not crew_pull:
			col.hp -= float(p.def.get("maul_damage", 100.0))
			fx.burst(col.pos + Vector3(0, 0.6, 0), Color(0.6, 0.02, 0.02, 0.1), 8, 3.0, 0.08, 0.6, 1.0)
			if col.hp > 0.0:
				# knocked down and wounded, but alive
				_release_post(col)
				col.state = S.DOWNED
				col.wounded = true
				col.timer = stun_time
				col.immune = immunity
				event.emit("%s was mauled by a %s - wounded" % [col.name, p.def.name], Color(1.0, 0.6, 0.3), col.pos)
				continue
		elif g[k + 2] == 1:
			continue  # maulers can't reach into a turret
		_release_post(col)
		if g[k + 2] == 1:
			col.state = S.DEAD
			killed += 1
			col.node.visible = false
			corpses.add_human(col.pos)
			fx.burst(col.pos + Vector3(0, 0.6, 0), Color(0.6, 0.02, 0.02, 0.1), 14, 4.0, 0.1, 0.8, 1.0)
			event.emit("%s was mauled to death by a %s" % [col.name, p.def.name], Color(1.0, 0.3, 0.25), col.pos)
		else:
			p.carry[i] = cid
			col.state = S.CARRIED
			col.last_seen = 0.0
			col.node.visible = true
			abductions += 1
			var how := "pulled from their turret" if crew_pull else "seized"
			event.emit("%s %s by a %s!" % [col.name, how, p.def.name], Color(1.0, 0.55, 0.2), col.pos)
	var cp := swarm.out_carried
	for k in range(0, cp.size(), 3):
		var col := colonists[int(cp[k])]
		if col.state != S.CARRIED:
			continue
		var np := Vector3(cp[k + 1], 0.25, cp[k + 2])
		var d := np - col.pos
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
		combat.despawn(e[k])
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
	_assign_timer -= dt
	if _assign_timer <= 0.0:
		_assign_timer = 0.5
		_assign()
	for col in colonists:
		_tick_colonist(col, dt)
	_write_grids()
	for cell: int in structures.turrets:
		var t: Turret = structures.turrets[cell]
		var crewed := crew_of.has(cell) and colonists[crew_of[cell]].state == S.CREWING
		t.crewed = crewed
		t.uncrewed_rate = uncrewed_rate
	_hunt_timer -= dt
	if _hunt_timer <= 0.0:
		_hunt_timer = hunt_interval
		var goals := PackedInt32Array()
		for col in colonists:
			match col.state:
				S.MOVING, S.DOWNED, S.RETURNING:
					var c := map.cell_of(col.pos)
					if c >= 0:
						goals.append(c)
				S.CREWING:
					goals.append(col.post)
		goals.sort()
		if goals != _last_goals:
			# only re-path the Snatchers when someone exposed actually moved cells
			_last_goals = goals
			hunt_field.set_goals(goals)
			hunt_field.request_rebuild()


## Crew every turret, most valuable first, from the reserve in the core.
func _assign() -> void:
	var open: Array = []
	for cell: int in structures.turrets:
		if not crew_of.has(cell):
			open.append(cell)
	if open.is_empty():
		return
	open.sort_custom(func(a, b):
		return GameConfig.build_cost(structures.ids[a]) * structures.tier_at(a) > GameConfig.build_cost(structures.ids[b]) * structures.tier_at(b))
	for cell: int in open:
		var col: Colonist = null
		for c in colonists:
			if c.state == S.RESERVE:
				col = c
				break
		if col == null:
			return
		col.post = cell
		crew_of[cell] = col.id
		col.state = S.MOVING
		col.pos = map.core_center
		col.node.visible = true
		col.node.rotation = Vector3.ZERO
		_plan_path(col, _adjacent_free(cell, col.pos))


func _release_post(col: Colonist) -> void:
	if col.post >= 0 and crew_of.get(col.post, -1) == col.id:
		crew_of.erase(col.post)
	col.post = -1


func _send_home(col: Colonist) -> void:
	_release_post(col)
	col.state = S.RETURNING
	_plan_path(col, map.world_to_cell(map.core_center))


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
	for r in range(1, 4):
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


## Walks along the path; returns true on arrival.
func _walk(col: Colonist, dt: float) -> bool:
	if col.path_i >= col.path.size():
		return true
	var step := walk_speed * dt * (0.6 if col.wounded else 1.0)
	while step > 0.0 and col.path_i < col.path.size():
		var cellv := col.path[col.path_i]
		if not _walkable(map.idx(cellv.x, cellv.y)):
			return false  # blocked by new construction: caller re-plans
		var target := Vector3(cellv.x + map.origin.x + 0.5, 0.0, cellv.y + map.origin.y + 0.5)
		var d := target - col.pos
		d.y = 0.0
		var l := d.length()
		if l <= step:
			col.pos = target
			step -= l
			col.path_i += 1
		else:
			col.pos += d / l * step
			col.node.rotation.y = atan2(d.x, d.z)
			step = 0.0
	return col.path_i >= col.path.size()


func _tick_colonist(col: Colonist, dt: float) -> void:
	if col.immune > 0.0:
		col.immune -= dt
	match col.state:
		S.MOVING:
			if not structures.turrets.has(col.post):
				_send_home(col)
				return
			var arrived := _walk(col, dt)
			if col.path.is_empty() or (not arrived and col.path_i < col.path.size() and not _walkable(map.idx(col.path[col.path_i].x, col.path[col.path_i].y))):
				_plan_path(col, _adjacent_free(col.post, col.pos))
				if col.path.is_empty():
					# unreachable post (walled off without a door): give it up
					event.emit("%s can't reach a turret - build a Blast Door" % col.name, Color(1.0, 0.8, 0.3), col.pos)
					_send_home(col)
				return
			if arrived:
				col.state = S.CREWING
				col.node.rotation = Vector3.ZERO
		S.CREWING:
			if not structures.turrets.has(col.post):
				return
			col.pos = map.cell_ground(col.post) + Vector3(0, 1.05, -0.28)
		S.DOWNED:
			col.node.rotation = Vector3(-PI * 0.5, col.node.rotation.y, 0.0)
			col.timer -= dt
			if col.timer <= 0.0:
				col.node.rotation = Vector3.ZERO
				_send_home(col)
		S.RETURNING:
			var arrived := _walk(col, dt)
			var home := map.world_to_cell(map.core_center)
			if col.path.is_empty() or (not arrived and col.path_i < col.path.size() and not _walkable(map.idx(col.path[col.path_i].x, col.path[col.path_i].y))):
				_plan_path(col, home)
			if arrived or col.pos.distance_to(map.core_center) < 1.6:
				col.node.visible = false
				if col.wounded:
					col.state = S.RECOVERING
					col.timer = recovery_time * recovery_mult
				else:
					col.state = S.RESERVE
		S.RECOVERING:
			col.timer -= dt
			if col.timer <= 0.0:
				col.wounded = false
				col.hp = max_hp
				col.state = S.RESERVE
				event.emit("%s is back on duty" % col.name, Color(0.6, 0.9, 1.0), map.core_center)
		S.CARRIED:
			col.last_seen += dt
			col.smear -= dt
			if col.smear <= 0.0:
				col.smear = 0.35
				fx.splat(Vector3(col.pos.x, 0.0, col.pos.z), Color(0.75, 0.05, 0.05), 0.22)
			if col.last_seen > 1.0:
				# carrier vanished without dying (despawned): drop where last seen
				drop(col.id, col.pos)
	if col.node.visible:
		var walking := col.state == S.MOVING or col.state == S.RETURNING
		var p := col.pos
		if col.state != S.CREWING:
			p.y = map.height_at(p.x, p.z) + (0.3 if col.state == S.CARRIED else 0.0)
		col.node.position = p
		_animate(col, walking, dt)


func _write_grids() -> void:
	for c in _exposed_written:
		map.colonist_at[c] = 0
	for c in _crew_written:
		map.crew_at[c] = 0
	_exposed_written.clear()
	_crew_written.clear()
	for col in colonists:
		match col.state:
			S.MOVING, S.DOWNED, S.RETURNING:
				var c := map.cell_of(col.pos)
				if c >= 0:
					map.colonist_at[c] = col.id + 1
					_exposed_written.append(c)
			S.CREWING:
				map.crew_at[col.post] = col.id + 1
				_crew_written.append(col.post)
