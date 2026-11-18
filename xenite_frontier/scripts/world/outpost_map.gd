class_name OutpostMap
extends Node3D
## Grid world: terrain kind per cell, spawn zones (canyon mouths) and the goal
## (the outpost core the swarm hunts). 1 cell = 1 metre. Cell (0,0) has its
## corner at world `origin` (x, z).

enum Kind { GROUND = 0, ROCK = 1, WALL = 2 }

signal changed

var w := 0
var h := 0
var origin := Vector2.ZERO
var kind := PackedByteArray()      # Kind per cell
var blocked := PackedByteArray()   # 1 = impassable (shared with flow field)
var cost := PackedByteArray()      # traversal multiplier 1..8
var goal_cells := PackedInt32Array()
var spawn_cells := PackedInt32Array()
var core_center := Vector3.ZERO

var _rock_mmi: MultiMeshInstance3D
var _wall_mmi: MultiMeshInstance3D
var _ground: MeshInstance3D
var _heat: MeshInstance3D
var _initial_kind := PackedByteArray()


func idx(x: int, z: int) -> int:
	return z * w + x


func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and z >= 0 and x < w and z < h


func cell_center(c: int) -> Vector3:
	return Vector3(origin.x + (c % w) + 0.5, 0.0, origin.y + (c / w) + 0.5)


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x - origin.x), floori(p.z - origin.y))


func set_kind(x: int, z: int, k: int) -> void:
	var c := idx(x, z)
	kind[c] = k
	blocked[c] = 1 if k != Kind.GROUND else 0


## Procedural benchmark map: a basin ringed by cliffs with three canyon mouths,
## rock outcrops forming narrow approaches, and a walled compound with airlock
## gaps around the core.
func generate_test_range(width: int, height: int, seed_value: int) -> void:
	w = width
	h = height
	origin = Vector2(-w * 0.5, -h * 0.5)
	var n := w * h
	kind.resize(n); kind.fill(Kind.GROUND)
	blocked.resize(n); blocked.fill(0)
	cost.resize(n); cost.fill(1)

	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.045
	noise.fractal_octaves = 3

	var core := Vector2i(w / 2, h - 26)
	var mouths := [Vector2i(w / 2, 0), Vector2i(0, h / 3), Vector2i(w - 1, h / 3)]

	for z in h:
		for x in w:
			var edge := x < 2 or z < 2 or x >= w - 2 or z >= h - 2
			var v := noise.get_noise_2d(x, z)
			var rock := edge or v > 0.28
			# keep the compound surroundings and canyon mouths clear
			if Vector2(x, z).distance_to(Vector2(core)) < 24.0:
				rock = edge
			for m: Vector2i in mouths:
				var d := Vector2(x, z).distance_to(Vector2(m))
				if d < 12.0:
					rock = false
			if rock:
				set_kind(x, z, Kind.ROCK)

	# carve three canyon corridors from each mouth toward the basin centre
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
						set_kind(cx, cz, Kind.GROUND)
	# re-open mouths through the border
	for m: Vector2i in mouths:
		for oz in range(-5, 6):
			for ox in range(-5, 6):
				var cx := m.x + ox
				var cz := m.y + oz
				if in_bounds(cx, cz):
					set_kind(cx, cz, Kind.GROUND)

	_build_compound(core)
	_initial_kind = kind.duplicate()

	# spawn zones: cells right inside each mouth
	spawn_cells = PackedInt32Array()
	for m: Vector2i in mouths:
		for oz in range(-4, 5):
			for ox in range(-4, 5):
				var cx := clampi(m.x + ox, 0, w - 1)
				var cz := clampi(m.y + oz, 0, h - 1)
				if blocked[idx(cx, cz)] == 0:
					spawn_cells.append(idx(cx, cz))
	_build_visuals()


func _build_compound(core: Vector2i) -> void:
	# outer wall ring 26x18 with four airlock gaps, inner ring 12x8 with two gaps
	_wall_rect(core, 13, 9, [Vector2i(0, -9), Vector2i(-13, 0), Vector2i(13, 0), Vector2i(0, 9)], 2)
	_wall_rect(core, 6, 4, [Vector2i(-6, 0), Vector2i(6, 0)], 1)
	# catwalk baffles inside the outer ring force zig-zag paths
	for x in range(core.x - 9, core.x - 2):
		set_kind(x, core.y - 6, Kind.WALL)
	for x in range(core.x + 3, core.x + 10):
		set_kind(x, core.y + 6, Kind.WALL)
	goal_cells = PackedInt32Array()
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			goal_cells.append(idx(core.x + ox, core.y + oz))
	core_center = cell_center(idx(core.x, core.y))


func _wall_rect(c: Vector2i, hx: int, hz: int, gaps: Array, gap_half: int) -> void:
	for x in range(c.x - hx, c.x + hx + 1):
		for z in [c.y - hz, c.y + hz]:
			set_kind(x, z, Kind.WALL)
	for z in range(c.y - hz, c.y + hz + 1):
		for x in [c.x - hx, c.x + hx]:
			set_kind(x, z, Kind.WALL)
	for g: Vector2i in gaps:
		var gc := c + g
		for o in range(-gap_half, gap_half + 1):
			if g.x == 0:
				set_kind(gc.x + o, gc.y, Kind.GROUND)
			else:
				set_kind(gc.x, gc.y + o, Kind.GROUND)


func reset_to_initial() -> void:
	kind = _initial_kind.duplicate()
	for c in kind.size():
		blocked[c] = 1 if kind[c] != Kind.GROUND else 0
	refresh_blocks()
	changed.emit()


## Toggles a player wall (rock cannot be removed). Returns true on change.
func toggle_wall(x: int, z: int) -> bool:
	if not in_bounds(x, z):
		return false
	var c := idx(x, z)
	if kind[c] == Kind.ROCK or c in goal_cells:
		return false
	set_kind(x, z, Kind.GROUND if kind[c] == Kind.WALL else Kind.WALL)
	refresh_blocks()
	changed.emit()
	return true


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

	_rock_mmi = _make_block_mmi(Color(0.27, 0.24, 0.28))
	_wall_mmi = _make_block_mmi(Color(0.45, 0.52, 0.58))
	_wall_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

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
	refresh_blocks()


func _make_block_mmi(col: Color) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	mm.mesh = bm
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = col
	mat.roughness = 0.95
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


## Rebuilds rock and wall instance buffers (called when the grid changes).
func refresh_blocks() -> void:
	var rocks: Array[int] = []
	var walls: Array[int] = []
	for c in kind.size():
		if kind[c] == Kind.ROCK:
			rocks.append(c)
		elif kind[c] == Kind.WALL:
			walls.append(c)
	_fill_blocks(_rock_mmi.multimesh, rocks, true)
	_fill_blocks(_wall_mmi.multimesh, walls, false)


func _fill_blocks(mm: MultiMesh, cells: Array[int], is_rock: bool) -> void:
	mm.instance_count = cells.size()
	for i in cells.size():
		var c := cells[i]
		var hsh := float((c * 2654435761) % 1000) / 1000.0
		var height := (1.6 + hsh * 2.4) if is_rock else 2.2
		var xf := Transform3D(Basis.from_scale(Vector3(1.0, height, 1.0)), cell_center(c) + Vector3(0, height * 0.5, 0))
		mm.set_instance_transform(i, xf)
		var shade := 0.75 + hsh * 0.35
		mm.set_instance_color(i, Color(shade, shade, shade))


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
			if blocked[c]:
				img.set_pixel(x, z, Color(0, 0, 0, 0))
			elif field.dist[c] >= FlowField.UNREACHABLE:
				img.set_pixel(x, z, Color(0.3, 0.3, 0.3, 0.6))
			else:
				var t := float(field.dist[c]) / maxd
				# banded so the wavefront is readable
				var band := 0.75 + 0.25 * float((field.dist[c] / 40) % 2)
				img.set_pixel(x, z, Color.from_hsv(0.55 - 0.55 * t, 0.9, band, 0.55))
	(_heat.material_override as StandardMaterial3D).albedo_texture = ImageTexture.create_from_image(img)
