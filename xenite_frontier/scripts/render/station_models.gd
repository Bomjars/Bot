class_name StationModels
extends RefCounted
## Mars-base-concept outpost visuals (industrial: off-white, hazard yellow, worn grey): hab dome, barrier walls that join into
## continuous lines, airlock blast doors, plus planet scatter (boulders,
## Xenite crystals) and plateau props. Off-white composite panels, grey
## structure, orange hazard trim, cyan lights.

# palette from the concept sheet "industrial/frontier - OUTPOST BUILDINGS v1"
const OFFW := Color("cfcbbf")
const WHITE := Color("e8e6df")
const GREY := Color("7a7d78")
const DARK := Color("3a3b38")
const MIDG := Color("5d5f5b")
const PAD := Color("575a56")
const BLK := Color("1d1d1b")
const YEL := Color("e3b51b")
const RED_L := Color(0.83, 0.16, 0.15, 0.0)     # alpha < 1 = emissive in station shader
const RED := Color("d42a26")
const WIN := Color(0.44, 0.84, 0.93, 0.35)
const GRN := Color("45d24a")
const GRN_L := Color(0.27, 0.82, 0.29, 0.2)
const ORG_L := Color(0.94, 0.54, 0.13, 0.15)
const TEAL_L := Color(0.31, 0.9, 0.82, 0.0)
const DRED := Color("8a2b2b")
const CRATE := Color("3b6e2c")
const ORANGE := YEL       # legacy names used by older callers
const CYAN := WIN
const AMBER := Color(1.0, 0.75, 0.2, 0.0)
const BAGS := MIDG

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



# ------------------------------------------------------------ helpers

static func _mi(a: MeshAcc) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = a.commit(true)
	mi.material_override = station_material()
	return mi


static func _box(a: MeshAcc, size: Vector3, pos: Vector3, col: Color, rot := Vector3.ZERO) -> void:
	a.add(MeshAcc.box(size.x, size.y, size.z), MeshAcc.xf(pos, rot), col)


## Yellow/black hazard band from `from` along +x (or +z) for `length` metres.
static func _hazard(a: MeshAcc, from: Vector3, length: float, along_x: bool, h := 0.1, d := 0.03) -> void:
	var n := maxi(2, int(length / 0.14))
	var seg := length / n
	for k in n:
		var p := from + (Vector3(seg * (k + 0.5), 0, 0) if along_x else Vector3(0, 0, seg * (k + 0.5)))
		_box(a, Vector3(seg, h, d) if along_x else Vector3(d, h, seg), p, YEL if k % 2 == 0 else BLK, Vector3(0, 0, 0))


static func _pad(a: MeshAcc, size: float, col := PAD) -> void:
	_box(a, Vector3(size, 0.1, size), Vector3(0, 0.05, 0), col)


static func _light(root: Node3D, pos: Vector3, col: Color, rng: float, energy: float) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = col
	l.omni_range = rng
	l.light_energy = energy
	root.add_child(l)


# ------------------------------------------------------------ structures

## Command Hab (3x3 core): low building, roof dome, window strips, antenna
## with a red beacon, hazard-striped pad.
static func build_command_hab(root: Node3D) -> void:
	var a := MeshAcc.new()
	_pad(a, 3.0)
	_hazard(a, Vector3(-1.5, 0.11, 1.46), 3.0, true, 0.03, 0.08)
	_hazard(a, Vector3(1.46, 0.11, -1.5), 3.0, false, 0.03, 0.08)
	_box(a, Vector3(2.3, 0.9, 2.3), Vector3(0, 0.55, 0), OFFW)
	_box(a, Vector3(2.45, 0.12, 2.45), Vector3(0, 1.06, 0), WHITE)
	for sx in [-0.55, 0.55]:
		_box(a, Vector3(0.75, 0.1, 0.03), Vector3(sx, 0.8, 1.16), WIN)
		_box(a, Vector3(0.03, 0.1, 0.75), Vector3(1.16, 0.8, sx), WIN)
	for k in 4:
		_box(a, Vector3(0.14, 0.14, 0.03), Vector3(-0.85 + k * 0.28, 0.42, 1.16), WIN)
	_box(a, Vector3(0.45, 0.55, 0.04), Vector3(0.55, 0.38, 1.16), BLK)
	_hazard(a, Vector3(0.3, 0.7, 1.17), 0.5, true, 0.06, 0.03)
	a.add(MeshAcc.cyl(0.8, 0.12, -1.0, 16), MeshAcc.xf(Vector3(-0.15, 1.16, -0.1)), WHITE)
	a.add(MeshAcc.dome(0.68, 0.62, 16, 4), MeshAcc.xf(Vector3(-0.15, 1.22, -0.1)), Color("d9d6cc"))
	a.add(MeshAcc.cyl(0.18, 0.32, -1.0, 8), MeshAcc.xf(Vector3(-0.95, 1.28, 0.9)), GREY)
	a.add(MeshAcc.cyl(0.03, 1.7, -1.0, 5), MeshAcc.xf(Vector3(0.85, 1.95, -0.7)), GREY)
	a.add(MeshAcc.box(0.4, 0.03, 0.03), MeshAcc.xf(Vector3(0.85, 2.3, -0.7)), GREY)
	a.add(MeshAcc.ball(0.07, 6, 3), MeshAcc.xf(Vector3(0.85, 2.82, -0.7)), RED_L)
	root.add_child(_mi(a))
	_light(root, Vector3(0, 1.6, 0), Color(0.45, 0.85, 1.0), 9.0, 1.2)
	_light(root, Vector3(0.85, 2.9, -0.7), Color(1.0, 0.2, 0.15), 3.0, 0.8)


## Wall post (every wall cell): dark post, cap, small yellow light.
static func wall_post_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	_box(a, Vector3(0.44, 0.3, 0.44), Vector3(0, 0.15, 0), MIDG)
	_box(a, Vector3(0.34, 2.4, 0.34), Vector3(0, 1.2, 0), DARK)
	_box(a, Vector3(0.38, 0.08, 0.38), Vector3(0, 2.42, 0), BLK)
	_box(a, Vector3(0.08, 0.08, 0.04), Vector3(0, 2.2, 0.18), Color(0.89, 0.71, 0.11, 0.0))
	return a.commit(true)


## Wall panel from a post to the next (+X, 1 m): pale panel with seams,
## hazard band at the foot, barbed rail on top.
static func wall_panel_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	_box(a, Vector3(0.9, 1.9, 0.2), Vector3(0.5, 1.1, 0), Color("b5b2a8"))
	for sx in [0.3, 0.7]:
		_box(a, Vector3(0.02, 1.8, 0.22), Vector3(sx, 1.1, 0), GREY)
	_box(a, Vector3(0.9, 0.22, 0.24), Vector3(0.5, 0.19, 0), MIDG)
	_hazard(a, Vector3(0.05, 0.38, 0.11), 0.9, true, 0.12, 0.03)
	_box(a, Vector3(1.0, 0.03, 0.03), Vector3(0.5, 2.12, 0), BLK)
	for k in 5:
		a.add(MeshAcc.cone(0.018, 0.12, 3), MeshAcc.xf(Vector3(0.1 + k * 0.2, 2.18, 0), Vector3(0, 0, 25.0 * (1 if k % 2 == 0 else -1))), BLK)
	return a.commit(true)


## Blast door: heavy dark frame, black slab with yellow chevrons, red lights.
static func door_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	for sx in [-0.42, 0.42]:
		_box(a, Vector3(0.24, 2.7, 0.62), Vector3(sx, 1.35, 0), DARK)
		_box(a, Vector3(0.1, 0.1, 0.06), Vector3(sx, 2.62, 0.3), RED_L)
	_box(a, Vector3(1.0, 0.28, 0.64), Vector3(0, 2.62, 0), DARK)
	_box(a, Vector3(0.62, 2.3, 0.34), Vector3(0, 1.18, 0), BLK)
	_box(a, Vector3(0.02, 2.3, 0.36), Vector3(0, 1.18, 0), DARK)
	for k in 5:
		var y := 0.35 + k * 0.42
		for sx: float in [-1.0, 1.0]:
			_box(a, Vector3(0.3, 0.07, 0.36), Vector3(sx * 0.15, y, 0), YEL, Vector3(0, 0, sx * 28.0))
	return a.commit(true)


## Floodlight: hazard-banded base, tripod mast, lamp head with three lights
## and a real spotlight cone angled at the ground.
static func build_floodlight(root: Node3D, radius: float) -> void:
	var a := MeshAcc.new()
	_box(a, Vector3(0.8, 0.12, 0.8), Vector3(0, 0.06, 0), MIDG)
	_box(a, Vector3(0.5, 0.25, 0.5), Vector3(0, 0.25, 0), DARK)
	_hazard(a, Vector3(-0.25, 0.3, 0.26), 0.5, true, 0.12, 0.02)
	for k in 3:
		var ang := k * TAU / 3.0
		a.add(MeshAcc.cyl(0.03, 1.0, 0.02, 4), MeshAcc.limb(Vector3(cos(ang) * 0.22, 0.35, sin(ang) * 0.22), Vector3(0, 2.95, 0)), BLK)
	var head := Basis.from_euler(Vector3(deg_to_rad(28), 0, 0))
	a.add(MeshAcc.box(0.55, 0.32, 0.3), Transform3D(head, Vector3(0, 3.05, 0)), BLK)
	for k in 3:
		a.add(MeshAcc.cyl(0.05, 0.03, -1.0, 6), Transform3D(head * Basis.from_euler(Vector3(PI * 0.5, 0, 0)), Vector3(-0.15 + k * 0.15, 3.05, 0) + head * Vector3(0, 0, 0.16)), Color(1.0, 0.95, 0.69, 0.0))
	root.add_child(_mi(a))
	var spot := SpotLight3D.new()
	spot.position = Vector3(0, 3.0, 0.1)
	spot.rotation = Vector3(deg_to_rad(-64), PI, 0)    # same way the lamp head faces (+Z, down)
	spot.spot_range = radius * 1.7
	spot.spot_angle = 55.0
	spot.light_energy = 3.0
	spot.light_color = Color(1.0, 0.95, 0.78)
	root.add_child(spot)
	_light(root, Vector3(0, 2.6, 0), Color(1.0, 0.92, 0.75), radius * 0.6, 0.5)


## Guard Post: cabin on four legs, slit window, hazard band, red light, ladder.
static func build_guard_post(root: Node3D) -> void:
	var a := MeshAcc.new()
	for sx in [-0.38, 0.38]:
		for sz in [-0.38, 0.38]:
			_box(a, Vector3(0.09, 2.05, 0.09), Vector3(sx, 1.02, sz), DARK)
	_box(a, Vector3(0.8, 0.05, 0.05), Vector3(0, 0.9, 0.38), DARK, Vector3(0, 0, 40))
	_box(a, Vector3(0.05, 0.05, 0.8), Vector3(0.38, 0.9, 0), DARK, Vector3(40, 0, 0))
	_box(a, Vector3(0.98, 0.1, 0.98), Vector3(0, 2.05, 0), DARK)
	_hazard(a, Vector3(-0.49, 2.14, 0.5), 0.98, true, 0.08, 0.02)
	_box(a, Vector3(0.9, 0.62, 0.9), Vector3(0, 2.45, 0), GREY)
	_box(a, Vector3(0.92, 0.12, 0.92), Vector3(0, 2.55, 0), BLK)
	_box(a, Vector3(1.08, 0.08, 1.08), Vector3(0, 2.8, 0), MIDG)
	a.add(MeshAcc.ball(0.05, 5, 3), MeshAcc.xf(Vector3(0, 2.88, 0)), RED_L)
	for sz in [-0.12, 0.12]:
		_box(a, Vector3(0.03, 2.05, 0.03), Vector3(0.52, 1.02, sz), YEL)
	for k in 7:
		_box(a, Vector3(0.03, 0.03, 0.24), Vector3(0.52, 0.25 + k * 0.28, 0), YEL)
	root.add_child(_mi(a))


## Construction scaffold sized to the footprint: yellow poles, crane jib
## with a hanging crate, orange work light.
static func build_scaffold(root: Node3D, height: float, fp := 1) -> void:
	var a := MeshAcc.new()
	var s := float(fp) * 0.5 - 0.08
	var hgt := maxf(1.2, height)
	_box(a, Vector3(s * 2.0, 0.08, s * 2.0), Vector3(0, 0.04, 0), MIDG)
	for sx in [-s, s]:
		for sz in [-s, s]:
			_box(a, Vector3(0.05, hgt, 0.05), Vector3(sx, hgt * 0.5, sz), YEL)
	for y in [0.4, hgt * 0.55, hgt - 0.05]:
		_box(a, Vector3(s * 2.0, 0.04, 0.04), Vector3(0, y, -s), YEL)
		_box(a, Vector3(s * 2.0, 0.04, 0.04), Vector3(0, y, s), YEL)
		_box(a, Vector3(0.04, 0.04, s * 2.0), Vector3(-s, y, 0), YEL)
		_box(a, Vector3(0.04, 0.04, s * 2.0), Vector3(s, y, 0), YEL)
	_box(a, Vector3(s * 1.6, 0.05, 0.25), Vector3(0, hgt * 0.55, 0), GREY)
	_box(a, Vector3(0.05, 0.6, 0.05), Vector3(s, hgt + 0.3, s), YEL)
	_box(a, Vector3(s * 1.6, 0.05, 0.05), Vector3(s * 0.2, hgt + 0.58, s), YEL, Vector3(0, 0, -8))
	_box(a, Vector3(0.01, 0.5, 0.01), Vector3(-s * 0.55, hgt + 0.3, s), BLK)
	_box(a, Vector3(0.2, 0.16, 0.2), Vector3(-s * 0.55, hgt, s), WHITE)
	a.add(MeshAcc.ball(0.05, 5, 3), MeshAcc.xf(Vector3(s, hgt + 0.65, s)), Color(0.94, 0.54, 0.13, 0.0))
	root.add_child(_mi(a))


## Harvester Bay (2x2): hangar with a red-lit intake, landing ring, tank, lamp.
static func build_bay(root: Node3D) -> void:
	var a := MeshAcc.new()
	_pad(a, 1.96)
	_box(a, Vector3(1.0, 0.85, 1.3), Vector3(0.42, 0.52, -0.15), OFFW)
	_box(a, Vector3(1.1, 0.1, 1.4), Vector3(0.42, 0.98, -0.15), WHITE)
	_box(a, Vector3(0.66, 0.6, 0.04), Vector3(0.42, 0.42, 0.51), BLK)
	_box(a, Vector3(0.56, 0.4, 0.02), Vector3(0.42, 0.36, 0.5), Color(0.54, 0.17, 0.17, 0.5))
	_hazard(a, Vector3(0.09, 0.78, 0.52), 0.66, true, 0.07, 0.02)
	for k in 3:
		_box(a, Vector3(0.03, 0.12, 0.16), Vector3(0.93, 0.66, -0.55 + k * 0.32), WIN)
	a.add(MeshAcc.cyl(0.42, 0.02, -1.0, 16), MeshAcc.xf(Vector3(-0.48, 0.11, 0.42)), YEL)
	a.add(MeshAcc.cyl(0.35, 0.025, -1.0, 16), MeshAcc.xf(Vector3(-0.48, 0.115, 0.42)), BLK)
	a.add(MeshAcc.cyl(0.24, 1.0, -1.0, 10), MeshAcc.xf(Vector3(-0.55, 0.6, -0.55)), GREY)
	a.add(MeshAcc.cyl(0.25, 0.06, -1.0, 10), MeshAcc.xf(Vector3(-0.55, 1.12, -0.55)), MIDG)
	_box(a, Vector3(0.03, 1.2, 0.03), Vector3(0.88, 0.6, -0.82), BLK)
	a.add(MeshAcc.ball(0.05, 5, 3), MeshAcc.xf(Vector3(0.88, 1.22, -0.82)), Color(0.94, 0.75, 0.2, 0.0))
	root.add_child(_mi(a))
	_light(root, Vector3(0.42, 0.5, 0.75), Color(0.85, 0.2, 0.15), 2.2, 0.6)


static func build_building(root: Node3D, id: String, fp := 2) -> void:
	if id == "guard_post":
		build_guard_post(root)
		return
	var a := MeshAcc.new()
	var S := float(fp) - 0.04
	match id:
		"mining_rig":
			_pad(a, S, DARK)
			for sx in [-0.55, 0.55]:
				for sz in [-0.55, 0.55]:
					a.add(MeshAcc.cyl(0.03, 1.0, 0.025, 4), MeshAcc.limb(Vector3(sx, 0.1, sz), Vector3(0, 3.1, 0)), BLK)
			for y: float in [0.9, 1.7]:
				var r := 0.55 * (1.0 - (y - 0.1) / 3.0)
				for k in 4:
					var ang := k * PI * 0.5
					_box(a, Vector3(r * 2.0, 0.03, 0.03), Vector3(0, y, 0) + Basis(Vector3.UP, ang) * Vector3(0, 0, r), BLK, Vector3(0, rad_to_deg(ang), 0))
			a.add(MeshAcc.ball(0.07, 5, 3), MeshAcc.xf(Vector3(0, 3.15, 0)), RED_L)
			a.add(MeshAcc.cyl(0.2, 1.5, 0.17, 8), MeshAcc.xf(Vector3(0, 0.85, 0)), BLK)
			a.add(MeshAcc.cyl(0.27, 0.12, -1.0, 8), MeshAcc.xf(Vector3(0, 0.2, 0)), GREY)
			for k in 4:
				var ang := k * PI * 0.5 + 0.6
				a.add(MeshAcc.cone(0.09, 0.45, 5), MeshAcc.xf(Vector3(cos(ang) * 0.62, 0.32, sin(ang) * 0.62), Vector3(10, 0, 15)), TEAL_L)
			_box(a, Vector3(0.36, 0.3, 0.36), Vector3(0.62, 0.25, 0.62), YEL)
			_hazard(a, Vector3(-0.9, 0.15, 0.9), 1.8, true, 0.08, 0.05)
		"hab_module":
			_pad(a, S)
			a.add(MeshAcc.capsule(0.5, 1.85, 12, 2), MeshAcc.xf(Vector3(-0.1, 0.62, -0.05), Vector3(0, 0, 90)), OFFW)
			_box(a, Vector3(1.7, 0.08, 0.9), Vector3(-0.1, 0.17, -0.05), YEL)
			for k in 5:
				_box(a, Vector3(0.16, 0.16, 0.04), Vector3(-0.75 + k * 0.32, 0.68, 0.45), WIN)
			_box(a, Vector3(0.2, 0.15, 0.2), Vector3(-0.3, 1.15, -0.05), GREY)
			a.add(MeshAcc.cyl(0.26, 0.6, -1.0, 10), MeshAcc.xf(Vector3(0.72, 0.4, 0.58)), OFFW)
			a.add(MeshAcc.ball(0.05, 5, 3), MeshAcc.xf(Vector3(0.72, 0.74, 0.58)), GRN_L)
		"barracks":
			_pad(a, S)
			_box(a, Vector3(1.7, 0.72, 1.35), Vector3(0, 0.46, -0.1), GREY)
			_box(a, Vector3(1.78, 0.72, 0.72), Vector3(0, 0.82, -0.1), MIDG, Vector3(45, 0, 0))
			_box(a, Vector3(1.72, 0.08, 0.03), Vector3(0, 0.58, 0.57), RED)
			for k in 3:
				_box(a, Vector3(0.2, 0.14, 0.03), Vector3(-0.55 + k * 0.35, 0.42, 0.58), WIN)
			_box(a, Vector3(0.28, 0.45, 0.04), Vector3(0.55, 0.32, 0.58), BLK)
			_box(a, Vector3(0.03, 1.6, 0.03), Vector3(-0.85, 0.9, 0.75), BLK)
			_box(a, Vector3(0.36, 0.22, 0.02), Vector3(-0.66, 1.55, 0.75), RED)
			_box(a, Vector3(0.24, 0.2, 0.24), Vector3(-0.55, 0.2, 0.78), CRATE)
			_box(a, Vector3(0.22, 0.18, 0.22), Vector3(-0.3, 0.19, 0.8), CRATE)
		"bio_refinery":
			_pad(a, S)
			a.add(MeshAcc.cyl(0.14, 2.3, 0.12, 8), MeshAcc.xf(Vector3(-0.7, 1.2, -0.45)), BLK)
			a.add(MeshAcc.cyl(0.42, 1.5, -1.0, 12), MeshAcc.xf(Vector3(-0.05, 0.85, -0.35)), OFFW)
			a.add(MeshAcc.cyl(0.44, 0.08, -1.0, 12), MeshAcc.xf(Vector3(-0.05, 1.63, -0.35)), GREY)
			a.add(MeshAcc.cyl(0.3, 1.0, -1.0, 10), MeshAcc.xf(Vector3(0.62, 0.6, -0.55)), GREY)
			_box(a, Vector3(0.7, 0.55, 0.6), Vector3(0.45, 0.38, 0.45), OFFW)
			_box(a, Vector3(0.36, 0.22, 0.03), Vector3(0.45, 0.4, 0.76), ORG_L)
			_hazard(a, Vector3(0.1, 0.16, 0.76), 0.7, true, 0.06, 0.02)
			_box(a, Vector3(0.22, 0.2, 0.22), Vector3(-0.7, 0.2, 0.7), RED)
			_box(a, Vector3(0.5, 0.05, 0.05), Vector3(0.3, 1.2, -0.45), GREY)
		"fabricator":
			_pad(a, S)
			_box(a, Vector3(1.6, 1.0, 1.35), Vector3(0, 0.6, -0.15), OFFW)
			_box(a, Vector3(1.66, 0.08, 1.4), Vector3(0, 1.12, -0.15), WHITE)
			for sx in [-0.45, -0.1]:
				a.add(MeshAcc.cyl(0.11, 0.42, -1.0, 8), MeshAcc.xf(Vector3(sx, 1.36, -0.45)), GREY)
			_box(a, Vector3(0.8, 0.7, 0.04), Vector3(-0.2, 0.45, 0.53), BLK)
			_box(a, Vector3(0.6, 0.5, 0.02), Vector3(-0.2, 0.42, 0.52), Color(0.3, 0.55, 0.85, 0.35))
			_hazard(a, Vector3(-0.6, 0.84, 0.54), 0.8, true, 0.06, 0.02)
			_box(a, Vector3(0.05, 0.7, 0.05), Vector3(0.55, 1.4, 0.3), YEL, Vector3(0, 0, -25))
			_box(a, Vector3(0.6, 0.05, 0.05), Vector3(0.4, 1.7, 0.3), YEL, Vector3(0, 0, 15))
			_box(a, Vector3(0.04, 0.4, 0.04), Vector3(0.14, 1.48, 0.3), YEL)
			_box(a, Vector3(0.25, 0.22, 0.25), Vector3(-0.75, 0.21, 0.75), GREY)
			_box(a, Vector3(0.22, 0.2, 0.22), Vector3(-0.5, 0.2, 0.8), MIDG)
		"armory":
			_pad(a, S)
			_box(a, Vector3(1.7, 0.7, 1.4), Vector3(0, 0.45, -0.15), DARK)
			_box(a, Vector3(1.8, 0.1, 1.55), Vector3(0, 0.86, -0.15), MIDG, Vector3(6, 0, 0))
			_box(a, Vector3(1.72, 0.07, 0.03), Vector3(0, 0.66, 0.56), RED)
			_box(a, Vector3(0.36, 0.45, 0.04), Vector3(0.0, 0.32, 0.57), BLK)
			_hazard(a, Vector3(-0.2, 0.6, 0.58), 0.4, true, 0.06, 0.02)
			for k in 3:
				_box(a, Vector3(0.24, 0.18, 0.2), Vector3(-0.65 + (k % 2) * 0.12, 0.19 + (k / 2) * 0.18, 0.75), CRATE)
			a.add(MeshAcc.cyl(0.1, 0.28, -1.0, 8), MeshAcc.xf(Vector3(0.7, 0.24, 0.75)), RED)
		"medbay":
			_pad(a, S)
			_box(a, Vector3(1.6, 0.8, 1.35), Vector3(0, 0.5, -0.15), WHITE)
			_box(a, Vector3(1.62, 0.08, 1.37), Vector3(0, 0.14, -0.15), GRN)
			_box(a, Vector3(0.9, 0.14, 0.75), Vector3(0.1, 0.97, -0.2), WHITE)
			a.add(MeshAcc.ball(0.06, 5, 3), MeshAcc.xf(Vector3(0.1, 1.08, -0.2)), GRN_L)
			_box(a, Vector3(0.36, 0.1, 0.03), Vector3(-0.35, 0.55, 0.53), GRN_L)
			_box(a, Vector3(0.1, 0.36, 0.03), Vector3(-0.35, 0.55, 0.53), GRN_L)
			for k in 2:
				_box(a, Vector3(0.2, 0.14, 0.03), Vector3(0.25 + k * 0.32, 0.6, 0.53), WIN)
			_box(a, Vector3(0.24, 0.45, 0.04), Vector3(0.55, 0.32, 0.53), BLK)
			a.add(MeshAcc.cyl(0.28, 0.02, -1.0, 14), MeshAcc.xf(Vector3(-0.62, 0.11, 0.72)), BLK)
			_box(a, Vector3(0.28, 0.025, 0.08), Vector3(-0.62, 0.125, 0.72), GRN)
			_box(a, Vector3(0.08, 0.025, 0.28), Vector3(-0.62, 0.125, 0.72), GRN)
		_:
			_pad(a, S)
			_box(a, Vector3(S * 0.8, 0.8, S * 0.8), Vector3(0, 0.5, 0), OFFW)
	root.add_child(_mi(a))
	if id == "fabricator":
		_light(root, Vector3(-0.2, 0.5, 0.9), Color(0.35, 0.6, 1.0), 2.0, 0.6)
	elif id == "bio_refinery":
		_light(root, Vector3(0.45, 0.4, 0.95), Color(1.0, 0.55, 0.15), 2.0, 0.6)
	elif id == "mining_rig":
		_light(root, Vector3(0, 0.6, 0), Color(0.3, 1.0, 0.85), 3.0, 0.8)


## Harvester drone per the sheet: white body, blue eye, four rotors, claw.
static func drone_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	_box(a, Vector3(0.36, 0.2, 0.32), Vector3.ZERO, OFFW)
	_box(a, Vector3(0.08, 0.06, 0.02), Vector3(0, 0.0, 0.17), WIN)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(a, Vector3(0.3, 0.03, 0.03), Vector3(sx * 0.26, 0.06, sz * 0.2), BLK, Vector3(0, sx * sz * 35.0, 0))
			a.add(MeshAcc.cyl(0.13, 0.02, -1.0, 10), MeshAcc.xf(Vector3(sx * 0.4, 0.1, sz * 0.3)), BLK)
			a.add(MeshAcc.cyl(0.03, 0.06, -1.0, 6), MeshAcc.xf(Vector3(sx * 0.4, 0.06, sz * 0.3)), DARK)
	_box(a, Vector3(0.02, 0.18, 0.02), Vector3(0, -0.18, 0), BLK)
	for sx in [-1.0, 1.0]:
		_box(a, Vector3(0.02, 0.1, 0.02), Vector3(sx * 0.04, -0.3, 0), BLK, Vector3(0, 0, sx * 25.0))
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


