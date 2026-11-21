class_name Structures
extends Node3D
## Everything the colonists build: walls, blast doors, floodlights, Harvester
## Bays and turrets. One cell each. HP lives in OutpostMap arrays so the
## threaded swarm can read it; damage is applied here on the main thread.
## Costs, upgrades, refunds and repairs go through the Economy.
## Placing, destroying or selling anything emits `nav_changed`, which triggers
## an async flow-field rebuild.

signal nav_changed
signal core_destroyed
signal built(cell: int, id: String)
signal removed(cell: int, id: String)
signal upgraded(cell: int, id: String, tier: int)

var map: OutpostMap
var fx: Fx
var economy: Economy
var turrets := {}            # cell -> Turret
var nodes := {}              # cell -> Node3D (turrets, bays, floodlights)
var ids := {}                # cell -> id
var tiers := {}              # cell -> tier (1-based)
var invested := {}           # cell -> Biomass spent on it (refund basis)
var defs := {}               # id -> def
var core_hp := 6000.0
var core_max := 6000.0
var core_invulnerable := false
var built_count := 0
var destroyed_count := 0
var light_radius_mult := 1.0  # Colony Charter: Engineering (M6)

var _post_mmi: MultiMeshInstance3D
var _panel_mmi: MultiMeshInstance3D
var _door_mmi: MultiMeshInstance3D
var _visual_dirty := true
var _visual_timer := 0.0
var _turret_nav := 28
var _turret_height := 1.6
var _node_mats := {}         # cell -> base material (damage tint)


func setup(m: OutpostMap, effects: Fx, econ: Economy) -> void:
	map = m
	fx = effects
	economy = econ
	for d in GameConfig.structure_defs:
		defs[d.id] = d
	for d in GameConfig.turret_defs:
		defs[d.id] = d
	_turret_nav = int(GameConfig.structures.get("turret_nav_cost", 28))
	_turret_height = float(GameConfig.structures.get("turret_height", 1.6))
	core_max = float(GameConfig.structures.get("core", {}).get("hp", 6000))
	core_hp = core_max
	_post_mmi = _make_mmi(StationModels.wall_post_mesh())
	_panel_mmi = _make_mmi(StationModels.wall_panel_mesh())
	_door_mmi = _make_mmi(StationModels.door_mesh())


func _make_mmi(mesh: Mesh) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mmi.multimesh = mm
	mmi.material_override = StationModels.station_material()
	add_child(mmi)
	return mmi


func is_turret(id: String) -> bool:
	return defs.has(id) and defs[id].has("damage_type")


func id_at(c: int) -> String:
	return ids.get(c, "")


func tier_at(c: int) -> int:
	return tiers.get(c, 1)


func light_radius() -> float:
	return float(defs.get("floodlight", {}).get("light_radius", 11.0)) * light_radius_mult


## Rebuilds the starting compound and refills the core.
func reset() -> void:
	for c in ids.keys():
		_remove(c)
	for c in map.kind.size():
		if map.kind[c] == OutpostMap.Kind.STRUCT:
			map.clear_structure(c)
	map.lit.fill(0)
	for entry in map.initial_structures:
		if place(entry[0], entry[1], false):
			invested[entry[0]] = float(GameConfig.build_cost(entry[1]))
	core_hp = core_max
	built_count = 0
	destroyed_count = 0
	_visual_dirty = true
	nav_changed.emit()


# ------------------------------------------------------------ build / sell

## Player build: checks placement and Biomass. Returns "" or a reason.
func try_build(c: int, id: String) -> String:
	if not defs.has(id):
		return "Unknown structure"
	if not map.can_build(c):
		return "Can't build there"
	var cost := GameConfig.build_cost(id)
	if not economy.can_afford(cost):
		return "Need %d Biomass" % cost
	economy.spend(cost)
	place(c, id)
	invested[c] = float(cost)
	return ""


## Places without cost (starting layout, sandbox).
func place(c: int, id: String, emit := true) -> bool:
	if not defs.has(id) or not map.can_build(c):
		return false
	var d: Dictionary = defs[id]
	var pos := map.cell_ground(c)
	if is_turret(id):
		map.put_structure(c, OutpostMap.SType.TURRET, float(d.hp), _turret_height, _turret_nav)
		var t := Turret.new()
		t.name = "Turret_%s_%d" % [id, c]
		add_child(t)
		t.setup(d, c, pos)
		turrets[c] = t
		nodes[c] = t
		_node_mats[c] = t.base_mat
	else:
		var st := OutpostMap.SType.WALL
		match id:
			"blast_door": st = OutpostMap.SType.DOOR
			"harvester_bay": st = OutpostMap.SType.BAY
			"floodlight": st = OutpostMap.SType.LIGHT
		map.put_structure(c, st, float(d.hp), float(d.height), int(d.nav_cost))
		if id == "harvester_bay" or id == "floodlight":
			var n := Node3D.new()
			n.name = "%s_%d" % [id, c]
			n.position = pos
			add_child(n)
			nodes[c] = n
			if id == "harvester_bay":
				_node_mats[c] = TurretModels.build_bay(n)
			else:
				_node_mats[c] = TurretModels.build_floodlight(n, light_radius())
				map.add_light(c, light_radius(), 1)
	ids[c] = id
	tiers[c] = 1
	invested[c] = 0.0
	built_count += 1
	_visual_dirty = true
	built.emit(c, id)
	if emit:
		nav_changed.emit()
	return true


func sell_value(c: int) -> int:
	return int(floor(invested.get(c, 0.0) * economy.refund_ratio))


## Player removal: refunds part of everything invested in it.
func sell(c: int) -> bool:
	if c < 0 or not ids.has(c):
		return false
	economy.refund(sell_value(c))
	fx.burst(map.cell_ground(c) + Vector3(0, 0.8, 0), Color(0.4, 0.9, 1.0, 1.0), 8, 3.0, 0.08, 0.4, 0.2)
	_remove(c)
	nav_changed.emit()
	return true


func _remove(c: int) -> void:
	var id: String = ids.get(c, "")
	if id == "floodlight":
		map.add_light(c, light_radius(), -1)
	if nodes.has(c):
		nodes[c].queue_free()
		nodes.erase(c)
	turrets.erase(c)
	_node_mats.erase(c)
	ids.erase(c)
	tiers.erase(c)
	invested.erase(c)
	map.clear_structure(c)
	_visual_dirty = true
	if id != "":
		removed.emit(c, id)


# ------------------------------------------------------------ upgrade / repair

func upgrade_cost(c: int) -> int:
	if not ids.has(c):
		return -1
	return GameConfig.upgrade_cost(ids[c], tier_at(c))


## Raises a turret / Harvester Bay one tier. Returns "" or a reason.
func upgrade(c: int) -> String:
	var cost := upgrade_cost(c)
	if cost < 0:
		return "Already at max tier" if ids.has(c) else "Nothing to upgrade"
	if not economy.can_afford(cost):
		return "Need %d Biomass" % cost
	economy.spend(cost)
	var id: String = ids[c]
	var tier := tier_at(c) + 1
	tiers[c] = tier
	invested[c] = invested.get(c, 0.0) + cost
	# HP grows with the tier, keeping the current damage ratio
	var td: Dictionary = GameConfig.tiers[clampi(tier - 1, 0, GameConfig.tiers.size() - 1)]
	var new_max := float(defs[id].hp) * float(td.get("hp", 1.0))
	var ratio := map.shp[c] / maxf(1.0, map.smax[c])
	map.smax[c] = new_max
	map.shp[c] = new_max * ratio
	if turrets.has(c):
		turrets[c].set_tier(tier)
	elif nodes.has(c):
		TurretModels.set_tier_pips(nodes[c], tier, Color(0.4, 1.0, 0.35))
	fx.burst(map.cell_ground(c) + Vector3(0, 1.0, 0), Color(1.0, 0.9, 0.4, 1.0), 14, 4.0, 0.1, 0.6, 0.0)
	upgraded.emit(c, id, tier)
	_visual_dirty = true
	return ""


func repair_cost(c: int) -> int:
	if not ids.has(c):
		return 0
	return int(ceil((map.smax[c] - map.shp[c]) * economy.repair_per_hp))


func repair(c: int) -> String:
	var cost := repair_cost(c)
	if cost <= 0:
		return "Undamaged"
	if not economy.can_afford(cost):
		return "Need %d Biomass" % cost
	economy.spend(cost)
	map.shp[c] = map.smax[c]
	invested[c] = invested.get(c, 0.0)
	fx.burst(map.cell_ground(c) + Vector3(0, 1.0, 0), Color(0.4, 0.8, 1.0, 1.0), 8, 2.5, 0.08, 0.5, 0.0)
	_visual_dirty = true
	return ""


# ------------------------------------------------------------ damage

func damage(c: int, amount: float) -> void:
	if map.kind[c] != OutpostMap.Kind.STRUCT:
		return
	var hp := map.shp[c] - amount
	map.shp[c] = hp
	if hp <= 0.0:
		_destroy(c)
	else:
		_visual_dirty = true


func _destroy(c: int) -> void:
	var p := map.cell_ground(c)
	var hgt := map.sheight[c]
	fx.burst(p + Vector3(0, hgt * 0.5, 0), Color(0.45, 0.47, 0.5, 0.0), 14, 6.0, 0.25, 2.0, 1.0)
	fx.burst(p + Vector3(0, hgt * 0.5, 0), Color(1.0, 0.6, 0.2, 1.0), 8, 5.0, 0.12, 0.4, 0.3)
	destroyed_count += 1
	_remove(c)
	nav_changed.emit()


## Bash damage from the swarm (merged per-chunk lists).
func apply_hits(cells: PackedInt32Array, dmg: PackedFloat32Array) -> void:
	for k in cells.size():
		damage(cells[k], dmg[k])


func damage_core(amount: float) -> void:
	if core_invulnerable or core_hp <= 0.0 or amount <= 0.0:
		return
	core_hp -= amount
	if core_hp <= 0.0:
		core_hp = 0.0
		fx.burst(map.core_center + Vector3(0, 2, 0), Color(0.3, 0.9, 1.0, 1.0), 60, 12.0, 0.3, 1.5, 0.5)
		core_destroyed.emit()


func tick(dt: float, combat: Combat) -> void:
	for t: Turret in turrets.values():
		t.tick(dt, combat)
	_visual_timer -= dt
	if _visual_dirty and _visual_timer <= 0.0:
		_visual_timer = 0.2
		_visual_dirty = false
		_refresh_visuals()


func _refresh_visuals() -> void:
	var walls: Array[int] = []
	var doors: Array[int] = []
	for c: int in ids:
		match map.stype[c]:
			OutpostMap.SType.WALL: walls.append(c)
			OutpostMap.SType.DOOR: doors.append(c)
		if _node_mats.has(c):
			var r := map.shp[c] / maxf(1.0, map.smax[c])
			_node_mats[c].albedo_color = Color(0.5, 0.52, 0.55).lerp(Color(0.55, 0.12, 0.05), 1.0 - r)
	# posts on every wall cell, panels joining it to wall/door neighbours
	# east and south (each joint drawn once), so lines read as continuous
	# barriers instead of blocks
	var post_xf: Array[Transform3D] = []
	var post_col: Array[Color] = []
	var panel_xf: Array[Transform3D] = []
	var panel_col: Array[Color] = []
	for c in walls:
		var p := map.cell_ground(c)
		var col := _tint(c)
		post_xf.append(Transform3D(Basis(), p))
		post_col.append(col)
		var x := c % map.w
		var z := c / map.w
		for o: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			if not map.in_bounds(x + o.x, z + o.y):
				continue
			var n := map.idx(x + o.x, z + o.y)
			var st := map.stype[n]
			if map.kind[n] != OutpostMap.Kind.STRUCT or (st != OutpostMap.SType.WALL and st != OutpostMap.SType.DOOR):
				continue
			var q := map.cell_ground(n)
			var b := Basis() if o.x == 1 else Basis(Vector3.UP, -PI * 0.5)
			panel_xf.append(Transform3D(b, Vector3(p.x, minf(p.y, q.y), p.z)))
			panel_col.append(col if st == OutpostMap.SType.WALL else col.lerp(_tint(n), 0.5))
	_fill_xf(_post_mmi.multimesh, post_xf, post_col)
	_fill_xf(_panel_mmi.multimesh, panel_xf, panel_col)
	var door_xf: Array[Transform3D] = []
	var door_col: Array[Color] = []
	for c in doors:
		var x := c % map.w
		var z := c / map.w
		# slab runs along the wall line (neighbours east/west = along X)
		var along_x := false
		for o in [-1, 1]:
			if map.in_bounds(x + o, z) and map.kind[map.idx(x + o, z)] == OutpostMap.Kind.STRUCT:
				along_x = true
		var b := Basis() if along_x else Basis(Vector3.UP, PI * 0.5)
		door_xf.append(Transform3D(b, map.cell_ground(c)))
		door_col.append(_tint(c))
	_fill_xf(_door_mmi.multimesh, door_xf, door_col)


func _tint(c: int) -> Color:
	var r := map.shp[c] / maxf(1.0, map.smax[c])
	var col := Color(1, 1, 1).lerp(Color(0.55, 0.18, 0.1), 1.0 - r)
	if map.climb[c]:
		col = col.lerp(Color(0.6, 0.9, 0.3), 0.3)  # the swarm can climb over here
	return col


func _fill_xf(mm: MultiMesh, xfs: Array[Transform3D], cols: Array[Color]) -> void:
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		mm.set_instance_color(i, cols[i])
