class_name OutpostMap
extends Node3D
## Grid world: terrain kind per cell, structures (walls, doors, turrets) with
## HP, corpse pile heights, spawn zones and the goal (the outpost core).
## 1 cell = 1 metre. Cell (0,0) has its corner at world `origin` (x, z).
##
## Navigation costs (consumed by the flow fields):
##   nav_cost    surface swarm: rock 0 (impassable), ground 1, structure =
##               its nav_cost (aliens bash through when a detour is longer),
##               climbable structure 2
##   burrow_cost tunnellers: rock 0, everything else 1

enum Kind { GROUND = 0, ROCK = 1, STRUCT = 2 }
enum SType { NONE = 0, WALL = 1, DOOR = 2, TURRET = 3, BAY = 4, LIGHT = 5 }

signal nav_changed

var w := 0
var h := 0
var origin := Vector2.ZERO
var kind := PackedByteArray()
var blocked := PackedByteArray()     # 1 = solid for movement (rock or structure)
var nav_cost := PackedByteArray()
var burrow_cost := PackedByteArray()
var stype := PackedByteArray()
var shp := PackedFloat32Array()      # structure HP
var smax := PackedFloat32Array()     # structure max HP
var sheight := PackedFloat32Array()  # structure height (aliens on top stand here)
var snav := PackedByteArray()        # structure's own nav cost (when not climbable)
var pile := PackedFloat32Array()     # corpse pile height, metres
var climb := PackedByteArray()       # 1 = structure is climbable via corpse pile
var lit := PackedByteArray()         # number of floodlights covering the cell (M5 night)
var goal_cells := PackedInt32Array()
var spawn_cells := PackedInt32Array()
var core_center := Vector3.ZERO
var initial_structures: Array = []   # [cell, "wall"|"blast_door"|turret id]

var climb_height := 1.6
var max_pile := 2.6

var _ground: MeshInstance3D
var _heat: MeshInstance3D
var _rock_mmi: MultiMeshInstance3D


func idx(x: int, z: int) -> int:
	return z * w + x


func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and z >= 0 and x < w and z < h


func cell_center(c: int) -> Vector3:
	return Vector3(origin.x + (c % w) + 0.5, 0.0, origin.y + (c / w) + 0.5)


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x - origin.x), floori(p.z - origin.y))


func cell_of(p: Vector3) -> int:
	var v := world_to_cell(p)
	if not in_bounds(v.x, v.y):
		return -1
	return idx(v.x, v.y)


func is_goal(c: int) -> bool:
	return c in goal_cells


func _set_terrain(x: int, z: int, k: int) -> void:
	var c := idx(x, z)
	kind[c] = k
	blocked[c] = 1 if k == Kind.ROCK else 0
	nav_cost[c] = 0 if k == Kind.ROCK else 1
	burrow_cost[c] = 0 if k == Kind.ROCK else 1


## Called by Structures. Writes all per-cell arrays for a new structure.
func put_structure(c: int, t: int, hp: float, height: float, cost: int) -> void:
	kind[c] = Kind.STRUCT
	blocked[c] = 1
	stype[c] = t
	shp[c] = hp
	smax[c] = hp
	sheight[c] = height
	snav[c] = cost
	_update_climb(c)


func clear_structure(c: int) -> void:
	kind[c] = Kind.GROUND
	blocked[c] = 0
	stype[c] = SType.NONE
	shp[c] = 0.0
	smax[c] = 0.0
	sheight[c] = 0.0
	climb[c] = 0
	nav_cost[c] = 1


func can_build(c: int) -> bool:
	return c >= 0 and kind[c] == Kind.GROUND and not is_goal(c)


## Adds (+1) or removes (-1) a floodlight's coverage.
func add_light(center: int, radius: float, sign_: int) -> void:
	var cx := center % w
	var cz := center / w
	var r := int(ceil(radius))
	for z in range(maxi(0, cz - r), mini(h, cz + r + 1)):
		for x in range(maxi(0, cx - r), mini(w, cx + r + 1)):
			if Vector2(x - cx, z - cz).length() <= radius:
				var c := idx(x, z)
				lit[c] = clampi(lit[c] + sign_, 0, 255)


# ------------------------------------------------------------- corpse piles

## Adds corpse height to a cell, returns the height the corpse rests at.
func add_pile(c: int, amount: float) -> float:
	var base := pile[c]
	var before := base >= climb_height
	pile[c] = minf(max_pile, base + amount)
	if not before and pile[c] >= climb_height:
		_refresh_climb_around(c)
	return base


func remove_pile(c: int, amount: float) -> void:
	var before := pile[c] >= climb_height
	pile[c] = maxf(0.0, pile[c] - amount)
	if before and pile[c] < climb_height:
		_refresh_climb_around(c)


func _refresh_climb_around(c: int) -> void:
	var x := c % w
	var z := c / w
	var changed := false
	for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if in_bounds(x + o.x, z + o.y):
			changed = _update_climb(idx(x + o.x, z + o.y)) or changed
	if changed:
		nav_changed.emit()


## A structure is climbable when a neighbouring corpse pile reaches climb
## height. Returns true if its state changed.
func _update_climb(c: int) -> bool:
	if kind[c] != Kind.STRUCT:
		return false
	var x := c % w
	var z := c / w
	var can := 0
	for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if in_bounds(x + o.x, z + o.y) and pile[idx(x + o.x, z + o.y)] >= climb_height:
			can = 1
	var was := climb[c]
	climb[c] = can
	nav_cost[c] = 2 if can else snav[c]
	return was != can


func climbable_count() -> int:
	var n := 0
	for c in climb.size():
		n += climb[c]
	return n


func reset_piles() -> void:
	pile.fill(0.0)
	climb.fill(0)
	for c in kind.size():
		if kind[c] == Kind.STRUCT:
			nav_cost[c] = snav[c]


# --------------------------------------------------------------- generation

## Procedural test range: a basin ringed by cliffs with three canyon mouths,
## rock outcrops forming narrow approaches, and a walled compound with airlock
## gaps around the core.
func generate_test_range(width: int, height: int, seed_value: int) -> void:
	w = width
	h = height
	origin = Vector2(-w * 0.5, -h * 0.5)
	var n := w * h
	for a in [kind, blocked, nav_cost, burrow_cost, stype, climb, snav, lit]:
		a.resize(n)
		a.fill(0)
	for a in [shp, smax, sheight, pile]:
		a.resize(n)
		a.fill(0.0)
	var sd := GameConfig.structures
	climb_height = float(sd.get("climb_height", climb_height))
	max_pile = float(sd.get("max_pile_height", max_pile))
	for z in h:
		for x in w:
			_set_terrain(x, z, Kind.GROUND)

	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.045
	noise.fractal_octaves = 3

	var core := Vector2i(w / 2, h - 26)
	var mouths := [Vector2i(w / 2, 0), Vector2i(0, h / 3), Vector2i(w - 1, h / 3)]

	for z in h:
		for x in w:
			var edge := x < 2 or z < 2 or x >= w - 2 or z >= h - 2
			var rock := edge or noise.get_noise_2d(x, z) > 0.28
			if Vector2(x, z).distance_to(Vector2(core)) < 24.0:
				rock = edge
			for m: Vector2i in mouths:
				if Vector2(x, z).distance_to(Vector2(m)) < 12.0:
					rock = false
			if rock:
				_set_terrain(x, z, Kind.ROCK)

	var basin := Vector2(w / 2, h / 2)
	for m: Vector2i in mouths:
		var a := Vector2(m)
		var steps := int(a.distance_to(basin))
		for s in steps:
			var p := a.lerp(basin, float(s) / steps)
			var half := 3 + int(2.0 * sin(s * 0.21))
			for oz in range(-half, half + 1):
				for ox in range(-half, half + 1):
					var cx := int(p.x) + ox
					var cz := int(p.y) + oz
					if cx >= 2 and cz >= 2 and cx < w - 2 and cz < h - 2:
						_set_terrain(cx, cz, Kind.GROUND)
	for m: Vector2i in mouths:
		for oz in range(-5, 6):
			for ox in range(-5, 6):
				if in_bounds(m.x + ox, m.y + oz):
					_set_terrain(m.x + ox, m.y + oz, Kind.GROUND)

	_plan_compound(core)

	spawn_cells = PackedInt32Array()
	for m: Vector2i in mouths:
		for oz in range(-4, 5):
			for ox in range(-4, 5):
				var cx := clampi(m.x + ox, 0, w - 1)
				var cz := clampi(m.y + oz, 0, h - 1)
				if kind[idx(cx, cz)] == Kind.GROUND:
					spawn_cells.append(idx(cx, cz))
	_build_visuals()


## Records the starting compound (walls, doors, a demo turret battery). The
## Structures node instantiates them so they get HP, visuals and turret logic.
func _plan_compound(core: Vector2i) -> void:
	initial_structures.clear()
	var planned := {}
	var put := func(x: int, z: int, t: String) -> void:
		planned[idx(x, z)] = t
	var unput := func(x: int, z: int) -> void:
		planned.erase(idx(x, z))
	# outer ring 27x19 with four airlocks (blast doors left OPEN as gaps: the
	# player decides what to seal), inner ring 13x9 with two gaps
	for ring in [[13, 9], [6, 4]]:
		var hx: int = ring[0]
		var hz: int = ring[1]
		for x in range(core.x - hx, core.x + hx + 1):
			put.call(x, core.y - hz, "wall")
			put.call(x, core.y + hz, "wall")
		for z in range(core.y - hz, core.y + hz + 1):
			put.call(core.x - hx, z, "wall")
			put.call(core.x + hx, z, "wall")
	for o in range(-2, 3):
		unput.call(core.x + o, core.y - 9)
		unput.call(core.x + o, core.y + 9)
		unput.call(core.x - 13, core.y + o)
		unput.call(core.x + 13, core.y + o)
	for o in range(-1, 2):
		unput.call(core.x - 6, core.y + o)
		unput.call(core.x + 6, core.y + o)
	# blast door frames beside the north airlock
	put.call(core.x - 3, core.y - 9, "blast_door")
	put.call(core.x + 3, core.y - 9, "blast_door")
	# catwalk baffles
	for x in range(core.x - 9, core.x - 2):
		put.call(x, core.y - 6, "wall")
	for x in range(core.x + 3, core.x + 10):
		put.call(x, core.y + 6, "wall")
	# starting kit: a Harvester Bay, a small battery and two floodlights.
	# Everything else is bought with Biomass.
	put.call(core.x + 3, core.y - 2, "harvester_bay")
	put.call(core.x - 4, core.y - 7, "autocannon")
	put.call(core.x + 4, core.y - 7, "flamethrower")
	put.call(core.x + 2, core.y + 2, "mortar")
	put.call(core.x - 9, core.y - 3, "floodlight")
	put.call(core.x + 9, core.y + 3, "floodlight")
	for c in planned:
		initial_structures.append([c, planned[c]])

	goal_cells = PackedInt32Array()
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			goal_cells.append(idx(core.x + ox, core.y + oz))
	core_center = cell_center(idx(core.x, core.y))


# ---------------------------------------------------------------- visuals

func _build_visuals() -> void:
	_ground = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(w, h)
	_ground.mesh = pm
	_ground.position = Vector3(origin.x + w * 0.5, 0.0, origin.y + h * 0.5)
	var gm := ShaderMaterial.new()
	gm.shader = preload("res://scripts/render/ground.gdshader")
	_ground.material_override = gm
	add_child(_ground)

	_rock_mmi = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var bm := BoxMesh.new()
	mm.mesh = bm
	_rock_mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.27, 0.24, 0.28)
	mat.roughness = 0.95
	_rock_mmi.material_override = mat
	_rock_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_rock_mmi)
	var rocks: Array[int] = []
	for c in kind.size():
		if kind[c] == Kind.ROCK:
			rocks.append(c)
	mm.instance_count = rocks.size()
	for i in rocks.size():
		var c := rocks[i]
		var hsh := float((c * 2654435761) % 1000) / 1000.0
		var hgt := 1.6 + hsh * 2.4
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(1.0, hgt, 1.0)), cell_center(c) + Vector3(0, hgt * 0.5, 0)))
		var shade := 0.75 + hsh * 0.35
		mm.set_instance_color(i, Color(shade, shade, shade))

	var core_mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.9; cyl.bottom_radius = 1.4; cyl.height = 3.0; cyl.radial_segments = 8
	core_mi.mesh = cyl
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.1, 0.5, 0.6)
	cm.emission_enabled = true
	cm.emission = Color(0.1, 0.85, 1.0)
	cm.emission_energy_multiplier = 2.5
	core_mi.material_override = cm
	core_mi.position = core_center + Vector3(0, 1.5, 0)
	add_child(core_mi)
	var core_light := OmniLight3D.new()
	core_light.light_color = Color(0.3, 0.9, 1.0)
	core_light.omni_range = 18.0
	core_light.light_energy = 2.0
	core_light.position = core_center + Vector3(0, 4, 0)
	add_child(core_light)


## Debug overlay: colours each cell by flow-field distance to the core.
func show_heatmap(field: FlowField, visible_on: bool) -> void:
	if _heat == null:
		_heat = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(w, h)
		_heat.mesh = pm
		_heat.position = Vector3(origin.x + w * 0.5, 0.03, origin.y + h * 0.5)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		_heat.material_override = m
		add_child(_heat)
	_heat.visible = visible_on
	if not visible_on:
		return
	var maxd := 1
	for c in field.dist.size():
		if field.dist[c] < FlowField.UNREACHABLE:
			maxd = maxi(maxd, field.dist[c])
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for z in h:
		for x in w:
			var c := idx(x, z)
			if kind[c] == Kind.ROCK:
				img.set_pixel(x, z, Color(0, 0, 0, 0))
			elif field.dist[c] >= FlowField.UNREACHABLE:
				img.set_pixel(x, z, Color(0.3, 0.3, 0.3, 0.6))
			else:
				var t := float(field.dist[c]) / maxd
				var band := 0.75 + 0.25 * float((field.dist[c] / 40) % 2)
				img.set_pixel(x, z, Color.from_hsv(0.55 - 0.55 * t, 0.9, band, 0.55))
	(_heat.material_override as StandardMaterial3D).albedo_texture = ImageTexture.create_from_image(img)
