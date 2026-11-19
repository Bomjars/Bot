class_name Structures
extends Node3D
## Everything the colonists build: walls, blast doors and turrets. One cell
## each. HP lives in OutpostMap arrays so the threaded swarm can read it;
## damage is applied here on the main thread. Destroying or placing anything
## emits `nav_changed`, which triggers an async flow-field rebuild.

signal nav_changed
signal core_destroyed

var map: OutpostMap
var fx: Fx
var turrets := {}            # cell -> Turret
var defs := {}               # id -> def (structures and turrets)
var core_hp := 6000.0
var core_max := 6000.0
var core_invulnerable := false
var built_count := 0
var destroyed_count := 0

var _wall_mmi: MultiMeshInstance3D
var _door_mmi: MultiMeshInstance3D
var _visual_dirty := true
var _visual_timer := 0.0
var _turret_nav := 28
var _turret_height := 1.6


func setup(m: OutpostMap, effects: Fx) -> void:
	map = m
	fx = effects
	for d in GameConfig.structure_defs:
		defs[d.id] = d
	for d in GameConfig.turret_defs:
		defs[d.id] = d
	_turret_nav = int(GameConfig.structures.get("turret_nav_cost", 28))
	_turret_height = float(GameConfig.structures.get("turret_height", 1.6))
	core_max = float(GameConfig.structures.get("core", {}).get("hp", 6000))
	core_hp = core_max
	_wall_mmi = _make_mmi(Color(0.5, 0.56, 0.62))
	_door_mmi = _make_mmi(Color(0.75, 0.62, 0.2))
	reset()


func _make_mmi(col: Color) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = BoxMesh.new()
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = col
	mat.roughness = 0.8
	mat.metallic = 0.3
	mmi.material_override = mat
	add_child(mmi)
	return mmi


func is_turret(id: String) -> bool:
	return defs.has(id) and defs[id].has("damage_type")


## Rebuilds the starting compound and refills the core.
func reset() -> void:
	for c in turrets.keys():
		turrets[c].queue_free()
	turrets.clear()
	for c in map.kind.size():
		if map.kind[c] == OutpostMap.Kind.STRUCT:
			map.clear_structure(c)
	for entry in map.initial_structures:
		place(entry[0], entry[1], false)
	core_hp = core_max
	built_count = 0
	destroyed_count = 0
	_visual_dirty = true
	nav_changed.emit()


func place(c: int, id: String, emit := true) -> bool:
	if not defs.has(id) or not map.can_build(c):
		return false
	var d: Dictionary = defs[id]
	if is_turret(id):
		map.put_structure(c, OutpostMap.SType.TURRET, float(d.hp), _turret_height, _turret_nav)
		var t := Turret.new()
		t.name = "Turret_%s_%d" % [id, c]
		add_child(t)
		t.setup(d, c, map.cell_center(c))
		turrets[c] = t
	else:
		var st := OutpostMap.SType.DOOR if id == "blast_door" else OutpostMap.SType.WALL
		map.put_structure(c, st, float(d.hp), float(d.height), int(d.nav_cost))
	built_count += 1
	_visual_dirty = true
	if emit:
		nav_changed.emit()
	return true


## Player removal (no debris, refund in M3).
func demolish(c: int) -> bool:
	if c < 0 or map.kind[c] != OutpostMap.Kind.STRUCT:
		return false
	_remove(c)
	nav_changed.emit()
	return true


func _remove(c: int) -> void:
	if turrets.has(c):
		turrets[c].queue_free()
		turrets.erase(c)
	map.clear_structure(c)
	_visual_dirty = true


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
	var p := map.cell_center(c)
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
	for c in map.kind.size():
		if map.kind[c] != OutpostMap.Kind.STRUCT:
			continue
		match map.stype[c]:
			OutpostMap.SType.WALL: walls.append(c)
			OutpostMap.SType.DOOR: doors.append(c)
			OutpostMap.SType.TURRET:
				if turrets.has(c):
					turrets[c].set_health_ratio(map.shp[c] / maxf(1.0, map.smax[c]))
	_fill(_wall_mmi.multimesh, walls)
	_fill(_door_mmi.multimesh, doors)


func _fill(mm: MultiMesh, cells: Array[int]) -> void:
	mm.instance_count = cells.size()
	for i in cells.size():
		var c := cells[i]
		var hgt := map.sheight[c]
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(0.98, hgt, 0.98)), map.cell_center(c) + Vector3(0, hgt * 0.5, 0)))
		var r := map.shp[c] / maxf(1.0, map.smax[c])
		var col := Color(1, 1, 1).lerp(Color(0.55, 0.18, 0.1), 1.0 - r)
		if map.climb[c]:
			col = col.lerp(Color(0.6, 0.9, 0.3), 0.25)  # tinted where the swarm can climb over
		mm.set_instance_color(i, col)
