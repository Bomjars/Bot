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
signal site_placed(cell: int, id: String)

var map: OutpostMap
var fx: Fx
var economy: Economy
var turrets := {}            # cell -> Turret
var nodes := {}              # cell -> Node3D (turrets, bays, floodlights)
var ids := {}                # cell -> id
var tiers := {}              # cell -> tier (1-based)
var invested := {}           # cell -> Biomass spent on it (refund basis)
var sites := {}              # cell -> {work, need}: under construction (workers build it)
var staff := {}              # cell -> colonist id working there (rigs, refinery, ...)
var cell_owner := {}              # every occupied cell -> its structure's anchor cell
var instant_build := false   # tests / free build: skip construction
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
	mm.use_custom_data = true   # x = damage (scorch marks in station.gdshader)
	mm.mesh = mesh
	mmi.multimesh = mm
	mmi.material_override = StationModels.station_material()
	add_child(mmi)
	return mmi


## Footprint: colony buildings are N x N (the anchor is the -x/-z corner).
func footprint(id: String) -> int:
	return int(defs.get(id, {}).get("footprint", 1))


func footprint_cells(anchor: int, id: String) -> Array[int]:
	var out: Array[int] = []
	var n := footprint(id)
	var ax := anchor % map.w
	var az := anchor / map.w
	for dz in n:
		for dx in n:
			if map.in_bounds(ax + dx, az + dz):
				out.append(map.idx(ax + dx, az + dz))
	return out


## Anchor of the structure covering `c` (-1 = none).
func anchor_of(c: int) -> int:
	return cell_owner.get(c, -1)


## Ground position at the middle of a structure's footprint.
func center_of(anchor: int) -> Vector3:
	var n := footprint(ids.get(anchor, ""))
	var p := map.cell_center(anchor) + Vector3((n - 1) * 0.5, 0.0, (n - 1) * 0.5)
	p.y = map.height_at(p.x, p.z)
	return p


func can_place(c: int, id: String) -> bool:
	if c < 0:
		return false
	var cells := footprint_cells(c, id)
	if cells.size() != footprint(id) * footprint(id):
		return false
	for k in cells:
		if not map.can_build(k):
			return false
	return true


func on_deposit(c: int, id: String) -> bool:
	for k in footprint_cells(c, id):
		if map.deposit[k]:
			return true
	return false


func _occupy(c: int, id: String, st: int, hp: float, hgt: float, nav: int) -> void:
	for k in footprint_cells(c, id):
		map.put_structure(k, st, hp, hgt, nav)
		cell_owner[k] = c


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
	sites.clear()
	staff.clear()
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
	if not can_place(c, id):
		return "Can't build there" if footprint(id) == 1 else "Needs a clear %dx%d area" % [footprint(id), footprint(id)]
	var d: Dictionary = defs[id]
	if d.get("needs_deposit", false) and not on_deposit(c, id):
		return "Build Mining Rigs on a glowing Xenite deposit"
	var cost := cost_of(id)
	if not economy.can_afford(cost):
		return "Need %d Biomass" % cost
	economy.spend(cost)
	if instant_build or economy.free_build:
		place(c, id)
	else:
		_place_site(c, id)
	invested[c] = float(cost)
	return ""


## Biomass cost after Fabricator discounts.
func cost_of(id: String) -> int:
	return int(round(GameConfig.build_cost(id) * cost_mult()))


func cost_mult() -> float:
	var n := mini(count_active("fabricator"), int(defs.get("fabricator", {}).get("max_effect", 2)))
	return 1.0 - float(defs.get("fabricator", {}).get("cost_reduction", 0.15)) * n


## A structure workers still have to build: solid (it blocks paths and the
## swarm can smash it) but fragile, with a scaffold instead of its model.
func _place_site(c: int, id: String) -> void:
	var d: Dictionary = defs[id]
	var hp := float(d.hp) * float(GameConfig.structures.get("construction_site_hp_ratio", 0.3))
	var st := _stype_of(id)
	var hgt := _turret_height if is_turret(id) else float(d.height)
	var nav := _turret_nav if is_turret(id) else int(d.nav_cost)
	ids[c] = id
	_occupy(c, id, st, hp, hgt, nav)
	tiers[c] = 1
	invested[c] = 0.0
	sites[c] = {"work": 0.0, "need": float(d.get("build_time", 5.0))}
	var n := Node3D.new()
	n.name = "site_%d" % c
	n.position = center_of(c)
	add_child(n)
	StationModels.build_scaffold(n, hgt, footprint(id))
	nodes[c] = n
	_visual_dirty = true
	site_placed.emit(c, id)
	nav_changed.emit()


func is_site(c: int) -> bool:
	return sites.has(c)


## Construction progress 0..1.
func site_progress(c: int) -> float:
	if not sites.has(c):
		return 1.0
	return clampf(sites[c].work / maxf(0.01, sites[c].need), 0.0, 1.0)


## Workers add build work; returns true when the structure is finished.
func work_on(c: int, amount: float) -> bool:
	if not sites.has(c):
		return true
	sites[c].work += amount
	if sites[c].work >= sites[c].need:
		_complete(c)
		return true
	return false


func _complete(c: int) -> void:
	var id: String = ids[c]
	var ratio := map.shp[c] / maxf(1.0, map.smax[c])
	var paid: float = invested.get(c, 0.0)
	sites.erase(c)
	if nodes.has(c):
		nodes[c].queue_free()
		nodes.erase(c)
	for k in footprint_cells(c, id):
		map.clear_structure(k)
		cell_owner.erase(k)
	ids.erase(c)
	place(c, id, false)
	invested[c] = paid
	map.shp[c] = map.smax[c] * ratio  # keeps damage the site took
	fx.burst(center_of(c) + Vector3(0, 1.0, 0), Color(0.5, 0.9, 1.0, 1.0), 10, 3.0, 0.08, 0.5, 0.0)


func _stype_of(id: String) -> int:
	if is_turret(id):
		return OutpostMap.SType.TURRET
	match id:
		"blast_door": return OutpostMap.SType.DOOR
		"wall": return OutpostMap.SType.WALL
		"harvester_bay": return OutpostMap.SType.BAY
		"floodlight": return OutpostMap.SType.LIGHT
	return OutpostMap.SType.BUILDING


# ------------------------------------------------------------ effects

## Built (not under construction) and staffed if it needs staff.
func is_active(c: int) -> bool:
	if not ids.has(c) or sites.has(c):
		return false
	var need := int(defs[ids[c]].get("staff", 0))
	return need == 0 or staff.has(c)


func count_active(id: String) -> int:
	var n := 0
	for c: int in ids:
		if ids[c] == id and is_active(c):
			n += 1
	return n


func count_built(id: String) -> int:
	var n := 0
	for c: int in ids:
		if ids[c] == id and not sites.has(c):
			n += 1
	return n


func cells_of(id: String) -> Array[int]:
	var out: Array[int] = []
	for c: int in ids:
		if ids[c] == id:
			out.append(c)
	return out


## Places without cost (starting layout, sandbox).
func place(c: int, id: String, emit := true) -> bool:
	if not defs.has(id) or not can_place(c, id):
		return false
	var d: Dictionary = defs[id]
	ids[c] = id
	var pos := center_of(c)
	if is_turret(id):
		_occupy(c, id, OutpostMap.SType.TURRET, float(d.hp), _turret_height, _turret_nav)
		var t := Turret.new()
		t.name = "Turret_%s_%d" % [id, c]
		add_child(t)
		t.setup(d, c, pos)
		turrets[c] = t
		nodes[c] = t
		_node_mats[c] = t.base_mat
	else:
		_occupy(c, id, _stype_of(id), float(d.hp), float(d.height), int(d.nav_cost))
		if id != "wall" and id != "blast_door":
			var n := Node3D.new()
			n.name = "%s_%d" % [id, c]
			n.position = pos
			add_child(n)
			nodes[c] = n
			if id == "harvester_bay":
				StationModels.build_bay(n)
			elif id == "floodlight":
				StationModels.build_floodlight(n, light_radius())
				map.add_light(c, light_radius(), 1)
			else:
				StationModels.build_building(n, id, footprint(id))
	ids[c] = id
	tiers[c] = 1
	invested[c] = 0.0
	built_count += 1
	if id != "wall" and id != "blast_door" and nodes.has(c):
		_add_contact(nodes[c], footprint(id))
	_visual_dirty = true
	built.emit(c, id)
	if emit:
		nav_changed.emit()
	return true


func sell_value(c: int) -> int:
	if sites.has(c):
		return int(invested.get(c, 0.0))  # cancelled construction: full refund
	return int(floor(invested.get(c, 0.0) * economy.refund_ratio))


## Player removal: refunds part of everything invested in it.
func sell(c: int) -> bool:
	c = anchor_of(c) if c >= 0 and cell_owner.has(c) else c
	if c < 0 or not ids.has(c):
		return false
	economy.refund(sell_value(c))
	fx.burst(center_of(c) + Vector3(0, 0.8, 0), Color(0.4, 0.9, 1.0, 1.0), 8, 3.0, 0.08, 0.4, 0.2)
	_remove(c)
	nav_changed.emit()
	return true


func _remove(c: int) -> void:
	var id: String = ids.get(c, "")
	if id == "floodlight" and not sites.has(c):
		map.add_light(c, light_radius(), -1)
	sites.erase(c)
	staff.erase(c)
	if nodes.has(c):
		nodes[c].queue_free()
		nodes.erase(c)
	turrets.erase(c)
	_node_mats.erase(c)
	for k in footprint_cells(c, id if id != "" else "wall"):
		map.clear_structure(k)
		cell_owner.erase(k)
	ids.erase(c)
	tiers.erase(c)
	invested.erase(c)
	_visual_dirty = true
	if id != "":
		removed.emit(c, id)


# ------------------------------------------------------------ upgrade / repair

func upgrade_cost(c: int) -> int:
	if not ids.has(c) or sites.has(c):
		return -1
	var base := GameConfig.upgrade_cost(ids[c], tier_at(c))
	if base < 0:
		return -1
	return int(round(base * cost_mult()))


## "" if allowed, else why not (tier III turret upgrades need an Armory).
func upgrade_block(c: int) -> String:
	if is_turret(ids.get(c, "")) and tier_at(c) >= 2 and count_active("armory") == 0:
		return "Tier III needs a staffed Armory"
	return ""


## Raises a turret / Harvester Bay one tier. Returns "" or a reason.
func upgrade(c: int) -> String:
	var cost := upgrade_cost(c)
	if cost < 0:
		return "Already at max tier" if ids.has(c) else "Nothing to upgrade"
	var block := upgrade_block(c)
	if block != "":
		return block
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
	c = cell_owner.get(c, c)
	if map.kind[c] != OutpostMap.Kind.STRUCT or not ids.has(c):
		return
	var hp := map.shp[c] - amount
	map.shp[c] = hp
	if hp <= 0.0:
		_destroy(c)
	else:
		_visual_dirty = true


func _destroy(c: int) -> void:
	var p := center_of(c)
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
	_smoke_t -= dt
	if _smoke_t <= 0.0 and fx:
		_smoke_t = 0.15
		_emit_damage_fx()
	_visual_timer -= dt
	if _visual_dirty and _visual_timer <= 0.0:
		_visual_timer = 0.2
		_visual_dirty = false
		_refresh_visuals()


## Damaged structures smoke (below 60% HP) and spark (below 35%). A few
## puffs per tick at most, so a battered wall line stays cheap.
var _smoke_t := 0.0
func _emit_damage_fx() -> void:
	var budget := 10
	for c: int in ids:
		if budget <= 0:
			break
		var r := map.shp[c] / maxf(1.0, map.smax[c])
		if r > 0.6 or sites.has(c):
			continue
		if randf() > 0.25 + (0.6 - r):
			continue
		budget -= 1
		var top := center_of(c) + Vector3(randf_range(-0.3, 0.3), map.sheight[c] * 0.85, randf_range(-0.3, 0.3))
		fx.particle(top, Vector3(0.35 + randf() * 0.3, 0.9 + randf() * 0.5, 0.15), Color(0.1, 0.09, 0.085, 0.0), randf_range(0.28, 0.5), randf_range(1.8, 3.0), -0.06)
		if r < 0.35 and randf() < 0.5:
			fx.burst(top, Color(1.0, 0.6, 0.15, 1.0), 3, 3.0, 0.035, 0.45, 1.0, 0.8)


func _refresh_visuals() -> void:
	var walls: Array[int] = []
	var doors: Array[int] = []
	for c: int in ids:
		if sites.has(c):
			continue
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
	var post_dmg := PackedFloat32Array()
	var panel_xf: Array[Transform3D] = []
	var panel_col: Array[Color] = []
	var panel_dmg := PackedFloat32Array()
	for c in walls:
		var p := map.cell_ground(c)
		var col := _tint(c)
		post_xf.append(Transform3D(Basis(), p))
		post_col.append(col)
		post_dmg.append(_damage_of(c))
		var x := c % map.w
		var z := c / map.w
		for o: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			if not map.in_bounds(x + o.x, z + o.y):
				continue
			var n := map.idx(x + o.x, z + o.y)
			var st := map.stype[n]
			if map.kind[n] != OutpostMap.Kind.STRUCT or sites.has(n) or (st != OutpostMap.SType.WALL and st != OutpostMap.SType.DOOR):
				continue
			var q := map.cell_ground(n)
			var b := Basis() if o.x == 1 else Basis(Vector3.UP, -PI * 0.5)
			panel_xf.append(Transform3D(b, Vector3(p.x, minf(p.y, q.y), p.z)))
			panel_col.append(col if st == OutpostMap.SType.WALL else col.lerp(_tint(n), 0.5))
			panel_dmg.append(maxf(_damage_of(c), _damage_of(n) * 0.5))
	_fill_xf(_post_mmi.multimesh, post_xf, post_col, post_dmg)
	_fill_xf(_panel_mmi.multimesh, panel_xf, panel_col, panel_dmg)
	var door_xf: Array[Transform3D] = []
	var door_col: Array[Color] = []
	var door_dmg := PackedFloat32Array()
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
		door_dmg.append(_damage_of(c))
	_fill_xf(_door_mmi.multimesh, door_xf, door_col, door_dmg)
	# buildings: scorch marks spread over their models as HP drops
	for c: int in nodes:
		if turrets.has(c) or sites.has(c):
			continue
		var d := _damage_of(c)
		var n: Node = nodes[c]
		if not is_instance_valid(n) or float(n.get_meta("dmg", -1.0)) == d:
			continue
		n.set_meta("dmg", d)
		for mi in n.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).set_instance_shader_parameter("damage", d)


## A soft dark patch on the ground under a building or turret (decal that
## only touches the terrain), so it sits in the regolith instead of on it.
static var _contact_tex: GradientTexture2D
func _add_contact(n: Node3D, fp: int) -> void:
	if _contact_tex == null:
		_contact_tex = GradientTexture2D.new()
		_contact_tex.fill = GradientTexture2D.FILL_RADIAL
		_contact_tex.fill_from = Vector2(0.5, 0.5)
		_contact_tex.fill_to = Vector2(1.0, 0.5)
		var g := Gradient.new()
		g.set_color(0, Color(0.06, 0.035, 0.025, 0.75))
		g.add_point(0.55, Color(0.08, 0.045, 0.03, 0.45))
		g.set_color(g.get_point_count() - 1, Color(0.1, 0.05, 0.03, 0.0))
		_contact_tex.gradient = g
		_contact_tex.width = 64
		_contact_tex.height = 64
	var d := Decal.new()
	d.texture_albedo = _contact_tex
	var s := float(fp) + 1.1
	d.size = Vector3(s, 3.0, s)
	d.cull_mask = OutpostMap.TERRAIN_LAYER
	d.upper_fade = 0.3
	d.lower_fade = 0.3
	n.add_child(d)


func _damage_of(c: int) -> float:
	return clampf(1.0 - map.shp[c] / maxf(1.0, map.smax[c]), 0.0, 1.0)


func _tint(c: int) -> Color:
	var r := map.shp[c] / maxf(1.0, map.smax[c])
	var col := Color(1, 1, 1).lerp(Color(0.75, 0.5, 0.42), 1.0 - r)
	if map.climb[c]:
		col = col.lerp(Color(0.6, 0.9, 0.3), 0.3)  # the swarm can climb over here
	return col


func _fill_xf(mm: MultiMesh, xfs: Array[Transform3D], cols: Array[Color], dmgs: PackedFloat32Array = PackedFloat32Array()) -> void:
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		mm.set_instance_color(i, cols[i])
		mm.set_instance_custom_data(i, Color(dmgs[i] if i < dmgs.size() else 0.0, 0, 0, 0))
