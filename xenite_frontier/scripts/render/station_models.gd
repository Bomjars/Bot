class_name StationModels
extends RefCounted
## Mars-base-concept outpost visuals: hab dome, barrier walls that join into
## continuous lines, airlock blast doors, plus planet scatter (boulders,
## Xenite crystals) and plateau props. Off-white composite panels, grey
## structure, orange hazard trim, cyan lights.

const WHITE := Color(0.86, 0.86, 0.84)
const GREY := Color(0.45, 0.47, 0.5)
const DARK := Color(0.16, 0.17, 0.19)
const ORANGE := Color(0.95, 0.45, 0.08)
const CYAN := Color(0.3, 0.9, 1.0, 0.0)      # alpha 0 = emissive in station shader
const AMBER := Color(1.0, 0.7, 0.2, 0.0)
const BAGS := Color(0.5, 0.36, 0.26)

static var _station_mat: ShaderMaterial
static var _rock_mat: StandardMaterial3D
static var _crystal_mat: StandardMaterial3D


## Shared lit material: vertex colour albedo, vertex alpha < 1 glows,
## multiplied by the MultiMesh instance colour (damage tint).
static func station_material() -> ShaderMaterial:
	if _station_mat == null:
		_station_mat = ShaderMaterial.new()
		_station_mat.shader = preload("res://scripts/render/station.gdshader")
	return _station_mat


static func rock_material() -> StandardMaterial3D:
	if _rock_mat == null:
		_rock_mat = StandardMaterial3D.new()
		_rock_mat.vertex_color_use_as_albedo = true
		_rock_mat.roughness = 0.95
	return _rock_mat


static func crystal_material() -> StandardMaterial3D:
	if _crystal_mat == null:
		_crystal_mat = StandardMaterial3D.new()
		_crystal_mat.albedo_color = Color(0.08, 0.45, 0.45)
		_crystal_mat.emission_enabled = true
		_crystal_mat.emission = Color(0.1, 0.8, 0.75)
		_crystal_mat.emission_energy_multiplier = 0.7
		_crystal_mat.roughness = 0.15
		_crystal_mat.metallic = 0.3
	return _crystal_mat


# ------------------------------------------------------------ planet scatter

static func boulder_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	a.add(MeshAcc.ball(1.0, 7, 4), Transform3D(), Color(0.24, 0.18, 0.17))
	a.jitter(0, 0.28, 7)
	return a.commit(true)


static func crystal_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	var tilts := [Vector3(0, 0, 0), Vector3(25, 40, 0), Vector3(-20, 120, 10), Vector3(15, 220, -25), Vector3(-30, 300, 0)]
	for k in tilts.size():
		var hgt: float = [1.4, 0.9, 1.0, 0.7, 0.8][k]
		var r: float = [0.16, 0.12, 0.13, 0.1, 0.11][k]
		var rot: Vector3 = tilts[k]
		var b := Basis.from_euler(rot * (PI / 180.0))
		a.add(MeshAcc.cyl(r, hgt, r * 0.9, 6), Transform3D(b, b * Vector3(0, hgt * 0.5, 0)), Color.WHITE)
		a.add(MeshAcc.cone(r * 0.9, r * 2.5, 6), Transform3D(b, b * Vector3(0, hgt + r * 1.25, 0)), Color.WHITE)
	return a.commit(true)


# ------------------------------------------------------------ structures

## Central hab dome (the outpost core).
static func build_hab_dome(root: Node3D) -> void:
	var a := MeshAcc.new()
	a.add(MeshAcc.cyl(1.6, 0.35, 1.55, 16), MeshAcc.xf(Vector3(0, 0.17, 0)), GREY)
	a.add(MeshAcc.dome(1.45, 1.35, 16, 5), MeshAcc.xf(Vector3(0, 0.35, 0)), WHITE)
	a.add(MeshAcc.cyl(1.47, 0.12, -1.0, 16), MeshAcc.xf(Vector3(0, 0.72, 0)), CYAN)  # window band
	# airlock tunnel and small side module
	a.add(MeshAcc.cyl(0.38, 1.2, -1.0, 10), MeshAcc.xf(Vector3(0, 0.5, 1.6), Vector3(90, 0, 0)), WHITE)
	a.add(MeshAcc.box(0.6, 0.7, 0.2), MeshAcc.xf(Vector3(0, 0.5, 2.2)), ORANGE)
	a.add(MeshAcc.cyl(0.45, 0.9, -1.0, 10), MeshAcc.xf(Vector3(1.55, 0.5, -0.6), Vector3(0, 0, 90)), WHITE)
	# comms mast + dish
	a.add(MeshAcc.cyl(0.05, 2.6, -1.0, 6), MeshAcc.xf(Vector3(-0.7, 2.3, -0.6)), GREY)
	a.add(MeshAcc.dome(0.45, 0.25, 10, 2), MeshAcc.xf(Vector3(-0.7, 3.4, -0.6), Vector3(140, 30, 0)), WHITE)
	a.add(MeshAcc.ball(0.08, 6, 3), MeshAcc.xf(Vector3(-0.7, 3.65, -0.6)), Color(1.0, 0.2, 0.15, 0.0))
	var mi := MeshInstance3D.new()
	mi.mesh = a.commit(true)
	mi.material_override = station_material()
	root.add_child(mi)
	var light := OmniLight3D.new()
	light.light_color = Color(0.3, 0.9, 1.0)
	light.omni_range = 16.0
	light.light_energy = 1.8
	light.position = Vector3(0, 3.0, 0)
	root.add_child(light)


## Wall post (every wall cell).
static func wall_post_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	a.add(MeshAcc.box(0.62, 0.45, 0.62), MeshAcc.xf(Vector3(0, 0.22, 0)), BAGS)
	a.add(MeshAcc.box(0.42, 2.25, 0.42), MeshAcc.xf(Vector3(0, 1.12, 0)), GREY)
	a.add(MeshAcc.box(0.46, 0.12, 0.46), MeshAcc.xf(Vector3(0, 2.28, 0)), DARK)
	a.add(MeshAcc.box(0.14, 0.08, 0.14), MeshAcc.xf(Vector3(0, 2.38, 0)), AMBER)
	return a.commit(true)


## Wall panel spanning from a post to the neighbouring post (+X, 1 m).
static func wall_panel_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	a.add(MeshAcc.box(1.0, 0.5, 0.7), MeshAcc.xf(Vector3(0.5, 0.25, 0)), BAGS)            # regolith berm
	a.add(MeshAcc.box(0.98, 1.55, 0.3), MeshAcc.xf(Vector3(0.5, 1.2, 0)), WHITE)         # composite panel
	a.add(MeshAcc.box(0.98, 0.16, 0.32), MeshAcc.xf(Vector3(0.5, 1.9, 0)), ORANGE)       # hazard band
	a.add(MeshAcc.box(0.06, 1.5, 0.34), MeshAcc.xf(Vector3(0.5, 1.2, 0)), GREY)          # rib
	a.add(MeshAcc.box(0.98, 0.06, 0.4), MeshAcc.xf(Vector3(0.5, 2.03, 0)), DARK)
	return a.commit(true)


## Airlock blast door, slab along X.
static func door_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	for sx in [-0.45, 0.45]:
		a.add(MeshAcc.box(0.22, 2.5, 0.6), MeshAcc.xf(Vector3(sx, 1.25, 0)), GREY)
	a.add(MeshAcc.box(0.98, 0.3, 0.62), MeshAcc.xf(Vector3(0, 2.4, 0)), DARK)
	a.add(MeshAcc.box(0.7, 2.1, 0.4), MeshAcc.xf(Vector3(0, 1.1, 0)), Color(0.85, 0.68, 0.15))
	for k in 4:
		a.add(MeshAcc.box(0.72, 0.12, 0.42), MeshAcc.xf(Vector3(0, 0.35 + k * 0.5, 0), Vector3(0, 0, 25)), DARK)
	a.add(MeshAcc.box(0.2, 0.08, 0.44), MeshAcc.xf(Vector3(0, 2.25, 0)), AMBER)
	return a.commit(true)


## Decorative prop for a rock plateau near the base: solar array, tanks or
## a comms tower. Returns a node.
static func plateau_prop(kind_id: int) -> Node3D:
	var a := MeshAcc.new()
	match kind_id % 3:
		0:  # solar array
			for k in 3:
				a.add(MeshAcc.box(0.08, 0.7, 0.08), MeshAcc.xf(Vector3(-1.0 + k, 0.35, 0)), GREY)
				a.add(MeshAcc.box(0.95, 0.04, 1.3), MeshAcc.xf(Vector3(-1.0 + k, 0.75, 0), Vector3(25, 0, 0)), Color(0.12, 0.18, 0.35))
		1:  # storage tanks
			for k in 2:
				a.add(MeshAcc.capsule(0.45, 1.8, 10, 2), MeshAcc.xf(Vector3(-0.5 + k, 0.5, 0), Vector3(0, 0, 90)), WHITE)
				a.add(MeshAcc.box(0.9, 0.12, 0.1), MeshAcc.xf(Vector3(-0.5 + k, 0.5, 0.45)), ORANGE)
		2:  # comms tower
			a.add(MeshAcc.cyl(0.35, 0.3, 0.3, 8), MeshAcc.xf(Vector3(0, 0.15, 0)), GREY)
			a.add(MeshAcc.cyl(0.06, 3.0, -1.0, 6), MeshAcc.xf(Vector3(0, 1.6, 0)), GREY)
			for k in 3:
				a.add(MeshAcc.box(0.5 - k * 0.12, 0.04, 0.04), MeshAcc.xf(Vector3(0, 1.2 + k * 0.7, 0)), GREY)
			a.add(MeshAcc.ball(0.09, 6, 3), MeshAcc.xf(Vector3(0, 3.15, 0)), Color(1.0, 0.2, 0.15, 0.0))
	var mi := MeshInstance3D.new()
	mi.mesh = a.commit(true)
	mi.material_override = station_material()
	var n := Node3D.new()
	n.add_child(mi)
	return n
