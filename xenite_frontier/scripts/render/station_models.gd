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
		_rock_mat.vertex_color_is_srgb = true
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


## Small low-poly stone for the pebble fields (instance colour tints it).
static func pebble_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	a.add(MeshAcc.ball(1.0, 5, 3), Transform3D(), Color(0.85, 0.8, 0.78))
	a.jitter(0, 0.3, 11)
	return a.commit(true)


## Abandoned mining kit left by earlier crews: rusted pipe, crushed crate,
## worn drill bit, survey stake, toppled panel, ore cart.
static func debris_mesh(kind_id: int) -> ArrayMesh:
	var a := MeshAcc.new()
	var rust := Color("6b3a22")
	var rust_d := Color("4a2a1c")
	match kind_id % 6:
		0:  # pipe segment with flanges, half buried
			a.add(MeshAcc.cyl(0.22, 2.4, -1.0, 8), MeshAcc.xf(Vector3(0, 0.12, 0), Vector3(0, 0, 90)), rust)
			for sx: float in [-1.15, 1.15]:
				a.add(MeshAcc.cyl(0.3, 0.08, -1.0, 8), MeshAcc.xf(Vector3(sx, 0.12, 0), Vector3(0, 0, 90)), rust_d)
		1:  # crushed supply crate
			a.add(MeshAcc.box(0.9, 0.45, 0.7), MeshAcc.xf(Vector3(0, 0.2, 0), Vector3(8, 20, -12)), Color("8a7a5a"))
			a.add(MeshAcc.box(0.92, 0.08, 0.72), MeshAcc.xf(Vector3(0, 0.25, 0), Vector3(8, 20, -12)), YEL.darkened(0.45))
			a.add(MeshAcc.box(0.4, 0.3, 0.35), MeshAcc.xf(Vector3(0.7, 0.13, 0.3), Vector3(0, -15, 0)), Color("6f6a5d"))
		2:  # worn drill bit on its side
			a.add(MeshAcc.cyl(0.18, 1.3, -1.0, 8), MeshAcc.xf(Vector3(0, 0.18, 0), Vector3(0, 0, 88)), MIDG.darkened(0.3))
			a.add(MeshAcc.cone(0.26, 0.6, 8), MeshAcc.xf(Vector3(0.95, 0.2, 0), Vector3(0, 0, -90)), rust)
		3:  # survey stake with a faded flag
			a.add(MeshAcc.box(0.05, 1.3, 0.05), MeshAcc.xf(Vector3(0, 0.6, 0), Vector3(6, 0, 4)), Color("9a9284"))
			a.add(MeshAcc.box(0.32, 0.2, 0.02), MeshAcc.xf(Vector3(0.18, 1.12, 0), Vector3(6, 0, 4)), Color("b86a3a"))
			a.add(MeshAcc.box(0.25, 0.06, 0.25), MeshAcc.xf(Vector3(0, 0.02, 0)), Color("5a5650"))
		4:  # toppled solar panel
			a.add(MeshAcc.box(1.4, 0.05, 0.9), MeshAcc.xf(Vector3(0, 0.25, 0), Vector3(-18, 30, 6)), Color(0.1, 0.13, 0.22))
			a.add(MeshAcc.box(0.07, 0.8, 0.07), MeshAcc.xf(Vector3(-0.3, 0.12, 0.4), Vector3(0, 0, 80)), GREY.darkened(0.3))
		5:  # ore cart, one wheel off
			a.add(MeshAcc.box(1.1, 0.5, 0.7), MeshAcc.xf(Vector3(0, 0.42, 0), Vector3(0, 0, -6)), rust)
			a.add(MeshAcc.box(1.0, 0.06, 0.6), MeshAcc.xf(Vector3(0, 0.66, 0), Vector3(0, 0, -6)), Color(0.18, 0.62, 0.56, 0.5))
			for k in 3:
				a.add(MeshAcc.cyl(0.16, 0.08, -1.0, 8), MeshAcc.xf(Vector3(-0.35 + (k % 2) * 0.7, 0.16, 0.38), Vector3(90, 0, 0)), DARK)
			a.add(MeshAcc.cyl(0.16, 0.08, -1.0, 8), MeshAcc.xf(Vector3(0.9, 0.04, -0.6), Vector3(0, 0, 0)), DARK)
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

const WIN_L := Color(0.52, 0.9, 1.0, 0.12)      # lit window
const LAMP_O := Color(1.0, 0.6, 0.16, 0.0)      # orange edge lamp
const LAMP_B := Color(0.45, 0.82, 1.0, 0.0)     # blue light strip
const LAMP_Y := Color(1.0, 0.82, 0.25, 0.0)     # yellow post lamp
const LAMP_W := Color(0.9, 0.97, 1.0, 0.0)      # white-blue flood lamp
const YEL_L := Color(1.0, 0.76, 0.12, 0.25)     # glowing chevrons
const RED_S := Color(0.88, 0.14, 0.12, 0.45)    # glowing red stripe
const OLIVE := Color("8a8a3e")                  # ammo crates
const STEEL := Color("9a9c97")
const PANEL := Color("d8d5cb")


static func _mi(a: MeshAcc) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = a.commit(true)
	mi.material_override = station_material()
	return mi


static func _box(a: MeshAcc, size: Vector3, pos: Vector3, col: Color, rot := Vector3.ZERO) -> void:
	a.add(MeshAcc.box(size.x, size.y, size.z), MeshAcc.xf(pos, rot), col)


## Bevelled box: the chunky look; bevels catch the light.
static func _bb(a: MeshAcc, size: Vector3, pos: Vector3, col: Color, bev := 0.035, rot := Vector3.ZERO) -> void:
	a.add_bevel_box(size, MeshAcc.xf(pos, rot), col, bev)


## Yellow/black hazard band from `from` along +x (or +z) for `length` metres.
static func _hazard(a: MeshAcc, from: Vector3, length: float, along_x: bool, h := 0.1, d := 0.03) -> void:
	var n := maxi(2, int(length / 0.14))
	var seg := length / n
	for k in n:
		var p := from + (Vector3(seg * (k + 0.5), 0, 0) if along_x else Vector3(0, 0, seg * (k + 0.5)))
		_box(a, Vector3(seg, h, d) if along_x else Vector3(d, h, seg), p, YEL if k % 2 == 0 else BLK)


## Base pad: bevelled slab, inset deck plate, orange lamps at the corners and
## along the front edge.
static func _pad(a: MeshAcc, size: float, col := PAD, lamps := true) -> void:
	_bb(a, Vector3(size, 0.12, size), Vector3(0, 0.06, 0), col.darkened(0.15), 0.04)
	_bb(a, Vector3(size - 0.16, 0.03, size - 0.16), Vector3(0, 0.125, 0), col, 0.012)
	if not lamps:
		return
	var h := size * 0.5 - 0.05
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_bb(a, Vector3(0.07, 0.035, 0.07), Vector3(sx * h, 0.135, sz * h), LAMP_O, 0.01)
	var n := int(size / 0.45)
	for k in range(1, n):
		var x := -size * 0.5 + size * float(k) / float(n)
		_box(a, Vector3(0.09, 0.025, 0.02), Vector3(x, 0.085, size * 0.5 + 0.004), LAMP_O)


## Window facing +Z (or along X when side): dark frame, lit pane.
static func _win(a: MeshAcc, pos: Vector3, w: float, h: float, side := false) -> void:
	var rot := Vector3(0, 90, 0) if side else Vector3.ZERO
	var out := Vector3(0.012, 0, 0) if side else Vector3(0, 0, 0.012)
	if side and pos.x < 0.0:
		out = -out
	_bb(a, Vector3(w + 0.05, h + 0.05, 0.03), pos, BLK, 0.01, rot)
	_box(a, Vector3(w, h, 0.02), pos + out, WIN_L, rot)


## Door facing +Z: frame, dark slab, a lamp above.
static func _door(a: MeshAcc, pos: Vector3, w: float, h: float, lamp := LAMP_O) -> void:
	_bb(a, Vector3(w + 0.07, h + 0.05, 0.035), pos + Vector3(0, h * 0.5, 0), MIDG, 0.012)
	_bb(a, Vector3(w, h, 0.03), pos + Vector3(0, h * 0.5 - 0.01, 0.012), DARK, 0.01)
	_box(a, Vector3(0.012, h * 0.85, 0.02), pos + Vector3(0, h * 0.45, 0.03), BLK)
	_bb(a, Vector3(w * 0.6, 0.035, 0.03), pos + Vector3(0, h + 0.07, 0.02), lamp, 0.008)


static func _roof_ac(a: MeshAcc, pos: Vector3, yaw := 0.0) -> void:
	_bb(a, Vector3(0.34, 0.16, 0.26), pos + Vector3(0, 0.08, 0), STEEL, 0.025, Vector3(0, yaw, 0))
	a.add(MeshAcc.cyl(0.08, 0.02, -1.0, 10), MeshAcc.xf(pos + Vector3(0.06, 0.17, 0)), DARK)
	for k in 3:
		_box(a, Vector3(0.02, 0.012, 0.2), pos + Vector3(-0.12 + k * 0.035, 0.165, 0), BLK, Vector3(0, yaw, 0))


static func _vent(a: MeshAcc, pos: Vector3, w: float, d: float) -> void:
	_bb(a, Vector3(w, 0.07, d), pos + Vector3(0, 0.035, 0), MIDG, 0.015)
	var n := int(w / 0.06)
	for k in n:
		_box(a, Vector3(0.018, 0.01, d - 0.05), pos + Vector3(-w * 0.5 + 0.04 + k * 0.06, 0.072, 0), BLK)


## Satellite dish on a stub mast, tilted up toward the sky.
static func _dish(a: MeshAcc, pos: Vector3, r: float, yaw := 30.0) -> void:
	a.add(MeshAcc.cyl(0.025, 0.22, -1.0, 6), MeshAcc.xf(pos + Vector3(0, 0.11, 0)), DARK)
	var tilt := Basis.from_euler(Vector3(deg_to_rad(-50), deg_to_rad(yaw), 0))
	var c := pos + Vector3(0, 0.24, 0)
	a.add(MeshAcc.cyl(0.03, r * 0.35, r, 12), Transform3D(tilt, c + tilt * Vector3(0, r * 0.12, 0)), PANEL)
	a.add(MeshAcc.cyl(r * 0.9, 0.01, -1.0, 12), Transform3D(tilt, c + tilt * Vector3(0, r * 0.3, 0)), GREY)
	a.add(MeshAcc.cyl(0.008, 1.0, -1.0, 4), MeshAcc.limb(c + tilt * Vector3(0, r * 0.3, 0), c + tilt * Vector3(0, r * 1.0, 0)), DARK)
	a.add(MeshAcc.ball(0.025, 5, 3), MeshAcc.xf(c + tilt * Vector3(0, r * 1.0, 0)), DARK)


static func _antenna(a: MeshAcc, pos: Vector3, h: float) -> void:
	a.add(MeshAcc.cyl(0.015, h, 0.008, 5), MeshAcc.xf(pos + Vector3(0, h * 0.5, 0)), DARK)
	a.add(MeshAcc.ball(0.03, 6, 3), MeshAcc.xf(pos + Vector3(0, h + 0.02, 0)), RED_L)


static func _crate(a: MeshAcc, pos: Vector3, s: Vector3, col: Color, yaw := 0.0) -> void:
	var r := Vector3(0, yaw, 0)
	_bb(a, s, pos + Vector3(0, s.y * 0.5, 0), col, 0.02, r)
	var b := Basis.from_euler(r * (PI / 180.0))
	for k: float in [-0.3, 0.3]:
		a.add(MeshAcc.box(s.x * 0.08, s.y + 0.006, s.z + 0.006), Transform3D(b, pos + Vector3(0, s.y * 0.5, 0) + b * Vector3(k * s.x, 0, 0)), col.darkened(0.35))
	a.add(MeshAcc.box(s.x * 0.4, s.y * 0.25, 0.01), Transform3D(b, pos + Vector3(0, s.y * 0.55, 0) + b * Vector3(0, 0, s.z * 0.5 + 0.004)), YEL.darkened(0.15))


static func _barrel(a: MeshAcc, pos: Vector3, col: Color) -> void:
	a.add(MeshAcc.cyl(0.1, 0.3, -1.0, 10), MeshAcc.xf(pos + Vector3(0, 0.15, 0)), col)
	for y: float in [0.06, 0.24]:
		a.add(MeshAcc.cyl(0.104, 0.02, -1.0, 10), MeshAcc.xf(pos + Vector3(0, y, 0)), col.darkened(0.35))


static func _pipe(a: MeshAcc, from: Vector3, to: Vector3, r: float, col: Color) -> void:
	a.add(MeshAcc.cyl(r, 1.0, -1.0, 8), MeshAcc.limb(from, to), col)
	for p: Vector3 in [from, to]:
		a.add(MeshAcc.cyl(r * 1.45, 1.0, -1.0, 8), MeshAcc.limb(p - (to - from).normalized() * 0.02, p + (to - from).normalized() * 0.02), DARK)


## Tank: bevel-capped cylinder with coloured bands.
static func _tank(a: MeshAcc, pos: Vector3, r: float, h: float, col: Color, band: Color, bands := 2) -> void:
	a.add(MeshAcc.cyl(r, h, -1.0, 16), MeshAcc.xf(pos + Vector3(0, h * 0.5, 0)), col)
	a.add(MeshAcc.dome(r, r * 0.6, 16, 3), MeshAcc.xf(pos + Vector3(0, h, 0)), col.darkened(0.08))
	a.add(MeshAcc.cyl(r * 1.04, 0.05, -1.0, 16), MeshAcc.xf(pos + Vector3(0, 0.03, 0)), DARK)
	for k in bands:
		a.add(MeshAcc.cyl(r * 1.02, 0.08, -1.0, 16), MeshAcc.xf(pos + Vector3(0, h * (0.3 + 0.35 * k), 0)), band)
	a.add(MeshAcc.cyl(r * 0.22, 0.08, -1.0, 8), MeshAcc.xf(pos + Vector3(0, h + r * 0.62, 0)), DARK)


# --- wall icons (facing +Z, centred on `c`)

static func _icon_gear(a: MeshAcc, c: Vector3, r: float, col: Color) -> void:
	a.add(MeshAcc.cyl(r * 0.72, 0.03, -1.0, 16), MeshAcc.xf(c, Vector3(90, 0, 0)), col)
	for k in 8:
		var ang := TAU * k / 8.0
		_box(a, Vector3(r * 0.3, r * 0.3, 0.03), c + Vector3(cos(ang), sin(ang), 0) * r * 0.82, col, Vector3(0, 0, rad_to_deg(ang)))
	a.add(MeshAcc.cyl(r * 0.3, 0.04, -1.0, 12), MeshAcc.xf(c + Vector3(0, 0, 0.004), Vector3(90, 0, 0)), DARK)


static func _icon_bullets(a: MeshAcc, c: Vector3, h: float, col: Color) -> void:
	for k in 3:
		var p := c + Vector3((k - 1) * h * 0.34, -h * 0.15, 0)
		a.add(MeshAcc.cyl(h * 0.1, h * 0.55, -1.0, 8), MeshAcc.xf(p, Vector3(0, 0, 0)), col)
		a.add(MeshAcc.cone(h * 0.1, h * 0.35, 8), MeshAcc.xf(p + Vector3(0, h * 0.45, 0)), col)


static func _icon_drop(a: MeshAcc, c: Vector3, h: float, col: Color) -> void:
	a.add(MeshAcc.ball(h * 0.3, 10, 6), MeshAcc.xf(c - Vector3(0, h * 0.12, 0), Vector3.ZERO, Vector3(1, 1, 0.35)), col)
	a.add(MeshAcc.cone(h * 0.27, h * 0.45, 10), MeshAcc.xf(c + Vector3(0, h * 0.22, 0), Vector3.ZERO, Vector3(1, 1, 0.35)), col)


static func _icon_cross(a: MeshAcc, c: Vector3, s: float, col: Color, face_up := false) -> void:
	var r := Vector3(90, 0, 0) if face_up else Vector3.ZERO
	_bb(a, Vector3(s, s * 0.34, 0.03), c, col, 0.01, r)
	_bb(a, Vector3(s * 0.34, s, 0.03), c, col, 0.01, r)


static func _light(root: Node3D, pos: Vector3, col: Color, rng: float, energy: float) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = col
	l.omni_range = rng
	l.light_energy = energy
	root.add_child(l)


# ------------------------------------------------------------ structures

## Command Hab (3x3 core): bevelled block with lit window bands, roof dome,
## AC unit, dish and antenna with a red beacon, a hazard-striped pad.
static func build_command_hab(root: Node3D) -> void:
	var a := MeshAcc.new()
	_pad(a, 3.0)
	_hazard(a, Vector3(-1.5, 0.13, 1.46), 3.0, true, 0.03, 0.08)
	_bb(a, Vector3(2.3, 0.95, 2.3), Vector3(0, 0.6, 0), OFFW, 0.06)
	_bb(a, Vector3(2.42, 0.12, 2.42), Vector3(0, 1.12, 0), WHITE, 0.04)
	_bb(a, Vector3(2.34, 0.08, 2.34), Vector3(0, 0.17, 0), MIDG, 0.02)
	for sx: float in [-0.55, 0.45]:
		_win(a, Vector3(sx, 0.82, 1.16), 0.62, 0.14)
		_win(a, Vector3(1.16, 0.82, sx), 0.62, 0.14, true)
		_win(a, Vector3(-1.16, 0.82, sx), 0.62, 0.14, true)
	for k in 3:
		_win(a, Vector3(-0.85 + k * 0.24, 0.45, 1.16), 0.14, 0.14)
	_door(a, Vector3(0.55, 0.13, 1.16), 0.42, 0.55)
	_hazard(a, Vector3(0.3, 0.76, 1.18), 0.5, true, 0.05, 0.03)
	a.add(MeshAcc.cyl(0.82, 0.12, -1.0, 20), MeshAcc.xf(Vector3(-0.15, 1.22, -0.1)), WHITE)
	a.add(MeshAcc.dome(0.7, 0.64, 20, 5), MeshAcc.xf(Vector3(-0.15, 1.28, -0.1)), Color("dcd8cd"))
	a.add(MeshAcc.cyl(0.72, 0.05, -1.0, 20), MeshAcc.xf(Vector3(-0.15, 1.32, -0.1)), LAMP_B)
	_roof_ac(a, Vector3(0.75, 1.18, 0.75))
	_dish(a, Vector3(-0.9, 1.18, 0.85), 0.22, 210.0)
	a.add(MeshAcc.cyl(0.18, 0.32, -1.0, 10), MeshAcc.xf(Vector3(-0.95, 1.34, -0.85)), GREY)
	_antenna(a, Vector3(0.85, 1.18, -0.75), 1.6)
	_box(a, Vector3(0.4, 0.03, 0.03), Vector3(0.85, 2.3, -0.75), GREY)
	root.add_child(_mi(a))
	_light(root, Vector3(0, 1.6, 0.6), Color(0.45, 0.85, 1.0), 9.0, 1.2)
	_light(root, Vector3(0.85, 2.9, -0.75), Color(1.0, 0.2, 0.15), 3.0, 0.8)


## Wall post (every wall cell): bevelled dark post, yellow lamp on top and a
## blue light strip, both faces.
static func wall_post_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	_bb(a, Vector3(0.46, 0.3, 0.46), Vector3(0, 0.15, 0), MIDG, 0.04)
	_bb(a, Vector3(0.34, 2.4, 0.34), Vector3(0, 1.2, 0), DARK, 0.04)
	_bb(a, Vector3(0.4, 0.1, 0.4), Vector3(0, 2.42, 0), BLK, 0.03)
	for sz: float in [-1.0, 1.0]:
		_bb(a, Vector3(0.12, 0.09, 0.03), Vector3(0, 2.2, sz * 0.17), LAMP_Y, 0.01)
		_box(a, Vector3(0.05, 0.36, 0.02), Vector3(0, 1.35, sz * 0.172), LAMP_B)
	return a.commit(true)


## Wall panel from a post to the next (+X, 1 m): bevelled white panel with
## grooves, hazard band at the foot, barbed rail on top.
static func wall_panel_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	_bb(a, Vector3(0.92, 1.95, 0.2), Vector3(0.5, 1.1, 0), PANEL, 0.04)
	for sx: float in [0.33, 0.67]:
		_box(a, Vector3(0.02, 1.75, 0.215), Vector3(sx, 1.12, 0), GREY)
	_box(a, Vector3(0.8, 0.02, 0.215), Vector3(0.5, 1.55, 0), GREY)
	_bb(a, Vector3(0.94, 0.24, 0.26), Vector3(0.5, 0.18, 0), MIDG, 0.03)
	_hazard(a, Vector3(0.05, 0.38, 0.11), 0.9, true, 0.1, 0.02)
	_hazard(a, Vector3(0.05, 0.38, -0.11), 0.9, true, 0.1, 0.02)
	_box(a, Vector3(1.0, 0.03, 0.03), Vector3(0.5, 2.14, 0), BLK)
	for k in 5:
		a.add(MeshAcc.cone(0.018, 0.12, 3), MeshAcc.xf(Vector3(0.1 + k * 0.2, 2.2, 0), Vector3(0, 0, 25.0 * (1 if k % 2 == 0 else -1))), BLK)
	return a.commit(true)


## Blast door: heavy bevelled frame, black slab with glowing yellow chevrons,
## orange lights on top, blue strips on the pillars.
static func door_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	for sx: float in [-0.42, 0.42]:
		_bb(a, Vector3(0.24, 2.75, 0.62), Vector3(sx, 1.37, 0), DARK, 0.04)
		for sz: float in [-1.0, 1.0]:
			_box(a, Vector3(0.05, 0.6, 0.02), Vector3(sx, 1.4, sz * 0.312), LAMP_B)
	_bb(a, Vector3(1.0, 0.3, 0.66), Vector3(0, 2.62, 0), DARK, 0.05)
	for sz: float in [-1.0, 1.0]:
		for sx: float in [-0.28, 0.28]:
			_bb(a, Vector3(0.12, 0.08, 0.03), Vector3(sx, 2.66, sz * 0.33), LAMP_O, 0.01)
	_bb(a, Vector3(0.62, 2.3, 0.34), Vector3(0, 1.18, 0), BLK, 0.03)
	_box(a, Vector3(0.02, 2.3, 0.36), Vector3(0, 1.18, 0), DARK)
	for k in 5:
		var y := 0.35 + k * 0.42
		for sx: float in [-1.0, 1.0]:
			_box(a, Vector3(0.3, 0.07, 0.36), Vector3(sx * 0.15, y, 0), YEL_L, Vector3(0, 0, sx * 28.0))
	return a.commit(true)


## Floodlight: hazard-banded base, tripod mast, a three-lamp head throwing a
## real spotlight cone.
static func build_floodlight(root: Node3D, radius: float) -> void:
	var a := MeshAcc.new()
	_bb(a, Vector3(0.8, 0.12, 0.8), Vector3(0, 0.06, 0), MIDG, 0.03)
	_bb(a, Vector3(0.5, 0.25, 0.5), Vector3(0, 0.25, 0), DARK, 0.03)
	_hazard(a, Vector3(-0.25, 0.3, 0.26), 0.5, true, 0.12, 0.02)
	for k in 3:
		var ang := k * TAU / 3.0
		a.add(MeshAcc.cyl(0.03, 1.0, 0.02, 5), MeshAcc.limb(Vector3(cos(ang) * 0.22, 0.35, sin(ang) * 0.22), Vector3(0, 2.95, 0)), BLK)
	for y: float in [1.1, 2.0]:
		var r := 0.22 * (1.0 - (y - 0.35) / 2.6)
		for k in 3:
			var a0 := k * TAU / 3.0
			var a1 := (k + 1) * TAU / 3.0
			a.add(MeshAcc.cyl(0.012, 1.0, -1.0, 4), MeshAcc.limb(Vector3(cos(a0) * r, y, sin(a0) * r), Vector3(cos(a1) * r, y, sin(a1) * r)), BLK)
	var head := Basis.from_euler(Vector3(deg_to_rad(28), 0, 0))
	a.add_bevel_box(Vector3(0.6, 0.34, 0.3), Transform3D(head, Vector3(0, 3.05, 0)), BLK, 0.04)
	for k in 3:
		a.add(MeshAcc.cyl(0.06, 0.03, -1.0, 8), Transform3D(head * Basis.from_euler(Vector3(PI * 0.5, 0, 0)), Vector3(-0.17 + k * 0.17, 3.05, 0) + head * Vector3(0, 0, 0.16)), LAMP_W)
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


## Guard Post: lattice legs, a cabin with lit windows all round, hazard
## band, red roof light and a yellow ladder.
static func build_guard_post(root: Node3D) -> void:
	var a := MeshAcc.new()
	for sx: float in [-0.38, 0.38]:
		for sz: float in [-0.38, 0.38]:
			_bb(a, Vector3(0.1, 2.05, 0.1), Vector3(sx, 1.02, sz), DARK, 0.02)
			_bb(a, Vector3(0.18, 0.06, 0.18), Vector3(sx, 0.03, sz), MIDG, 0.015)
	for y: float in [0.55, 1.35]:
		for k in 4:
			var p0 := Vector3([-0.38, 0.38, 0.38, -0.38][k], y, [-0.38, -0.38, 0.38, 0.38][k])
			var p1 := Vector3([0.38, 0.38, -0.38, -0.38][k], y + 0.6, [-0.38, 0.38, 0.38, -0.38][k])
			a.add(MeshAcc.cyl(0.018, 1.0, -1.0, 4), MeshAcc.limb(p0, p1), DARK)
	_bb(a, Vector3(1.0, 0.1, 1.0), Vector3(0, 2.05, 0), DARK, 0.03)
	_hazard(a, Vector3(-0.5, 2.14, 0.505), 1.0, true, 0.08, 0.02)
	_bb(a, Vector3(0.9, 0.64, 0.9), Vector3(0, 2.45, 0), GREY, 0.04)
	for k in 4:
		var yaw := k * 90.0
		var b := Basis.from_euler(Vector3(0, deg_to_rad(yaw), 0))
		a.add(MeshAcc.box(0.62, 0.15, 0.02), Transform3D(b, Vector3(0, 2.55, 0) + b * Vector3(0, 0, 0.456)), WIN_L)
		a.add_bevel_box(Vector3(0.68, 0.2, 0.03), Transform3D(b, Vector3(0, 2.55, 0) + b * Vector3(0, 0, 0.448)), BLK, 0.01)
	_bb(a, Vector3(1.1, 0.09, 1.1), Vector3(0, 2.82, 0), MIDG, 0.03)
	a.add(MeshAcc.ball(0.06, 6, 3), MeshAcc.xf(Vector3(0, 2.92, 0)), RED_L)
	for sz: float in [-0.12, 0.12]:
		_box(a, Vector3(0.03, 2.05, 0.03), Vector3(0.53, 1.02, sz), YEL)
	for k in 7:
		_box(a, Vector3(0.03, 0.03, 0.24), Vector3(0.53, 0.25 + k * 0.28, 0), YEL)
	root.add_child(_mi(a))


## Construction scaffold sized to the footprint: yellow poles, crane jib
## with a hanging crate, orange work light.
static func build_scaffold(root: Node3D, height: float, fp := 1) -> void:
	var a := MeshAcc.new()
	var s := float(fp) * 0.5 - 0.08
	var hgt := maxf(1.2, height)
	_bb(a, Vector3(s * 2.0, 0.08, s * 2.0), Vector3(0, 0.04, 0), MIDG, 0.02)
	for sx: float in [-s, s]:
		for sz: float in [-s, s]:
			_box(a, Vector3(0.05, hgt, 0.05), Vector3(sx, hgt * 0.5, sz), YEL)
	for y: float in [0.4, hgt * 0.55, hgt - 0.05]:
		_box(a, Vector3(s * 2.0, 0.04, 0.04), Vector3(0, y, -s), YEL)
		_box(a, Vector3(s * 2.0, 0.04, 0.04), Vector3(0, y, s), YEL)
		_box(a, Vector3(0.04, 0.04, s * 2.0), Vector3(-s, y, 0), YEL)
		_box(a, Vector3(0.04, 0.04, s * 2.0), Vector3(s, y, 0), YEL)
	_box(a, Vector3(s * 1.6, 0.05, 0.25), Vector3(0, hgt * 0.55, 0), GREY)
	_box(a, Vector3(0.05, 0.6, 0.05), Vector3(s, hgt + 0.3, s), YEL)
	_box(a, Vector3(s * 1.6, 0.05, 0.05), Vector3(s * 0.2, hgt + 0.58, s), YEL, Vector3(0, 0, -8))
	_box(a, Vector3(0.01, 0.5, 0.01), Vector3(-s * 0.55, hgt + 0.3, s), BLK)
	_crate(a, Vector3(-s * 0.55, hgt - 0.08, s), Vector3(0.2, 0.16, 0.2), WHITE)
	a.add(MeshAcc.ball(0.05, 5, 3), MeshAcc.xf(Vector3(s, hgt + 0.65, s)), LAMP_O)
	root.add_child(_mi(a))


## Harvester Bay (2x2): hangar with a glowing orange roll-up door and a lit
## window band, plus a marked landing pad for the drones.
static func build_bay(root: Node3D) -> void:
	var a := MeshAcc.new()
	_pad(a, 1.96)
	_bb(a, Vector3(1.0, 0.85, 1.25), Vector3(0.42, 0.55, -0.2), OFFW, 0.05)
	_bb(a, Vector3(1.08, 0.1, 1.33), Vector3(0.42, 1.01, -0.2), WHITE, 0.03)
	# roll-up door glowing from inside
	_bb(a, Vector3(0.7, 0.62, 0.04), Vector3(0.42, 0.45, 0.43), MIDG, 0.015)
	for k in 5:
		_box(a, Vector3(0.6, 0.075, 0.02), Vector3(0.42, 0.2 + k * 0.1, 0.45), Color(0.62, 0.22, 0.08, 0.35))
	_bb(a, Vector3(0.5, 0.04, 0.03), Vector3(0.42, 0.82, 0.45), LAMP_O, 0.01)
	for k in 3:
		_win(a, Vector3(0.93, 0.72, -0.6 + k * 0.32), 0.18, 0.12, true)
	_roof_ac(a, Vector3(0.5, 1.06, -0.45))
	# landing pad: dark square, yellow ring, cross marks, corner lamps
	var lp := Vector3(-0.48, 0.13, 0.42)
	_bb(a, Vector3(0.86, 0.04, 0.86), lp + Vector3(0, 0.02, 0), BLK, 0.015)
	a.add(MeshAcc.cyl(0.34, 0.012, -1.0, 24), MeshAcc.xf(lp + Vector3(0, 0.046, 0)), YEL)
	a.add(MeshAcc.cyl(0.29, 0.014, -1.0, 24), MeshAcc.xf(lp + Vector3(0, 0.048, 0)), BLK)
	_box(a, Vector3(0.36, 0.012, 0.06), lp + Vector3(0, 0.05, 0), YEL, Vector3(0, 45, 0))
	_box(a, Vector3(0.36, 0.012, 0.06), lp + Vector3(0, 0.05, 0), YEL, Vector3(0, -45, 0))
	for sx: float in [-0.38, 0.38]:
		for sz: float in [-0.38, 0.38]:
			_box(a, Vector3(0.05, 0.02, 0.05), lp + Vector3(sx, 0.05, sz), LAMP_O)
	_tank(a, Vector3(-0.58, 0.13, -0.55), 0.22, 0.75, GREY, MIDG, 1)
	_box(a, Vector3(0.03, 1.2, 0.03), Vector3(0.88, 0.7, -0.85), BLK)
	a.add(MeshAcc.ball(0.05, 5, 3), MeshAcc.xf(Vector3(0.88, 1.32, -0.85)), AMBER)
	root.add_child(_mi(a))
	_light(root, Vector3(0.42, 0.5, 0.75), Color(1.0, 0.5, 0.15), 2.4, 0.7)


static func build_building(root: Node3D, id: String, fp := 2) -> void:
	if id == "guard_post":
		build_guard_post(root)
		return
	var a := MeshAcc.new()
	var S := float(fp) - 0.04
	match id:
		"mining_rig":
			_pad(a, S, DARK)
			for sx: float in [-0.55, 0.55]:
				for sz: float in [-0.55, 0.55]:
					a.add(MeshAcc.cyl(0.035, 1.0, 0.025, 5), MeshAcc.limb(Vector3(sx, 0.12, sz), Vector3(0, 3.1, 0)), BLK)
			for y: float in [0.8, 1.45, 2.05, 2.55]:
				var r := 0.55 * (1.0 - (y - 0.12) / 2.98)
				for k in 4:
					var ang := k * PI * 0.5
					_box(a, Vector3(r * 2.0, 0.03, 0.03), Vector3(0, y, 0) + Basis(Vector3.UP, ang) * Vector3(0, 0, r), BLK, Vector3(0, rad_to_deg(ang), 0))
				for k in 4:
					var ang := k * PI * 0.5 + PI * 0.25
					var y2 := y + 0.6
					var r2 := 0.55 * (1.0 - (y2 - 0.12) / 2.98)
					a.add(MeshAcc.cyl(0.012, 1.0, -1.0, 4), MeshAcc.limb(Vector3(cos(ang), 0, sin(ang)) * r * 1.41 + Vector3(0, y, 0), Vector3(cos(ang + PI * 0.5), 0, sin(ang + PI * 0.5)) * r2 * 1.41 + Vector3(0, minf(y2, 3.0), 0)), DARK)
			# blue light column up the tower, a dish and a beacon on top
			_box(a, Vector3(0.05, 2.3, 0.05), Vector3(0, 1.75, 0.02), LAMP_B)
			_dish(a, Vector3(0.12, 2.45, 0.1), 0.2, 30.0)
			a.add(MeshAcc.ball(0.08, 6, 3), MeshAcc.xf(Vector3(0, 3.15, 0)), RED_L)
			a.add(MeshAcc.cyl(0.2, 1.4, 0.17, 10), MeshAcc.xf(Vector3(0, 0.82, 0)), BLK)
			_bb(a, Vector3(0.62, 0.16, 0.62), Vector3(0, 0.22, 0), GREY, 0.03)
			for k in 5:
				var ang := k * TAU / 5.0 + 0.6
				a.add(MeshAcc.cone(0.09, 0.45, 5), MeshAcc.xf(Vector3(cos(ang) * 0.62, 0.32, sin(ang) * 0.62), Vector3(10, 0, 15)), TEAL_L)
			_crate(a, Vector3(0.62, 0.13, 0.62), Vector3(0.32, 0.26, 0.32), YEL)
			_hazard(a, Vector3(-0.9, 0.15, 0.9), 1.8, true, 0.07, 0.05)
		"hab_module":
			_pad(a, S)
			a.add(MeshAcc.capsule(0.5, 1.85, 16, 3), MeshAcc.xf(Vector3(-0.1, 0.66, -0.05), Vector3(0, 0, 90)), OFFW)
			_bb(a, Vector3(1.75, 0.1, 0.92), Vector3(-0.1, 0.2, -0.05), YEL, 0.03)
			_bb(a, Vector3(1.85, 0.06, 0.96), Vector3(-0.1, 0.15, -0.05), MIDG, 0.02)
			for k in 5:
				_win(a, Vector3(-0.75 + k * 0.32, 0.7, 0.45), 0.16, 0.15)
			_vent(a, Vector3(-0.35, 1.13, -0.05), 0.42, 0.26)
			_roof_ac(a, Vector3(0.25, 1.1, -0.05))
			_tank(a, Vector3(0.72, 0.13, 0.58), 0.22, 0.5, OFFW, MIDG, 1)
			a.add(MeshAcc.ball(0.05, 5, 3), MeshAcc.xf(Vector3(0.72, 0.8, 0.58)), GRN_L)
		"barracks":
			_pad(a, S)
			_bb(a, Vector3(1.7, 0.78, 1.35), Vector3(0, 0.52, -0.1), GREY, 0.05)
			_bb(a, Vector3(1.8, 0.12, 1.45), Vector3(0, 0.96, -0.1), DARK, 0.04)
			_bb(a, Vector3(1.72, 0.09, 1.37), Vector3(0, 0.7, -0.1), RED_S, 0.015)
			for k in 3:
				_win(a, Vector3(-0.6 + k * 0.32, 0.45, 0.58), 0.2, 0.14)
			for k in 2:
				_win(a, Vector3(0.86, 0.45, -0.4 + k * 0.4), 0.22, 0.14, true)
			_door(a, Vector3(0.55, 0.13, 0.575), 0.26, 0.42)
			_roof_ac(a, Vector3(-0.4, 1.02, -0.3))
			_roof_ac(a, Vector3(0.1, 1.02, -0.3))
			_dish(a, Vector3(0.55, 1.02, -0.3), 0.2, 200.0)
			a.add(MeshAcc.cyl(0.018, 1.7, -1.0, 6), MeshAcc.xf(Vector3(-0.85, 0.95, 0.75)), BLK)
			_box(a, Vector3(0.38, 0.24, 0.02), Vector3(-0.65, 1.66, 0.75), RED, Vector3(0, 0, -4))
			_crate(a, Vector3(-0.5, 0.13, 0.78), Vector3(0.26, 0.2, 0.22), OLIVE, 8.0)
			_crate(a, Vector3(-0.22, 0.13, 0.8), Vector3(0.24, 0.18, 0.2), OLIVE, -6.0)
			_crate(a, Vector3(-0.38, 0.33, 0.78), Vector3(0.22, 0.16, 0.2), OLIVE, 15.0)
		"bio_refinery":
			_pad(a, S)
			_tank(a, Vector3(-0.15, 0.13, -0.38), 0.42, 1.35, Color("e3e0d8"), Color(0.95, 0.62, 0.15), 2)
			_tank(a, Vector3(0.6, 0.13, -0.52), 0.28, 0.95, STEEL, YEL, 1)
			a.add(MeshAcc.cyl(0.14, 2.35, 0.12, 10), MeshAcc.xf(Vector3(-0.75, 1.3, -0.5)), BLK)
			a.add(MeshAcc.cyl(0.16, 0.08, -1.0, 10), MeshAcc.xf(Vector3(-0.75, 2.45, -0.5)), DARK)
			_pipe(a, Vector3(-0.75, 1.0, -0.5), Vector3(-0.42, 1.0, -0.4), 0.05, DARK)
			_pipe(a, Vector3(0.12, 0.85, -0.4), Vector3(0.45, 0.85, -0.5), 0.05, DARK)
			_pipe(a, Vector3(0.6, 0.35, -0.25), Vector3(0.6, 0.35, 0.15), 0.045, MIDG)
			# furnace unit with a glowing mouth and a fuel-drop sign
			_bb(a, Vector3(0.7, 0.55, 0.58), Vector3(0.4, 0.42, 0.42), OFFW, 0.04)
			_bb(a, Vector3(0.74, 0.07, 0.62), Vector3(0.4, 0.72, 0.42), MIDG, 0.02)
			_bb(a, Vector3(0.36, 0.18, 0.03), Vector3(0.4, 0.3, 0.72), Color(1.0, 0.5, 0.1, 0.0), 0.01)
			_bb(a, Vector3(0.28, 0.28, 0.03), Vector3(0.4, 0.55, 0.715), DARK, 0.01)
			_icon_drop(a, Vector3(0.4, 0.55, 0.735), 0.22, LAMP_O)
			_hazard(a, Vector3(0.05, 0.18, 0.72), 0.7, true, 0.05, 0.02)
			_crate(a, Vector3(-0.72, 0.13, 0.7), Vector3(0.24, 0.2, 0.22), RED, 10.0)
			_barrel(a, Vector3(-0.42, 0.13, 0.75), YEL.darkened(0.1))
		"fabricator":
			_pad(a, S)
			_bb(a, Vector3(1.6, 1.0, 1.35), Vector3(0, 0.63, -0.15), OFFW, 0.05)
			_bb(a, Vector3(1.68, 0.09, 1.43), Vector3(0, 1.16, -0.15), WHITE, 0.03)
			# big door: hazard frame, blue-lit interior
			_hazard(a, Vector3(-0.68, 0.94, 0.53), 0.86, true, 0.07, 0.03)
			_box(a, Vector3(0.07, 0.75, 0.03), Vector3(-0.68, 0.52, 0.53), YEL)
			_box(a, Vector3(0.07, 0.75, 0.03), Vector3(0.18, 0.52, 0.53), YEL)
			_bb(a, Vector3(0.78, 0.74, 0.03), Vector3(-0.25, 0.5, 0.525), BLK, 0.01)
			_box(a, Vector3(0.7, 0.05, 0.02), Vector3(-0.25, 0.84, 0.54), LAMP_B)
			_box(a, Vector3(0.66, 0.5, 0.01), Vector3(-0.25, 0.45, 0.534), Color(0.25, 0.45, 0.8, 0.45))
			_icon_gear(a, Vector3(0.5, 0.65, 0.54), 0.17, MIDG)
			_win(a, Vector3(0.82, 0.7, -0.4), 0.3, 0.14, true)
			_vent(a, Vector3(-0.35, 1.2, -0.45), 0.5, 0.36)
			for sx: float in [0.2, 0.42]:
				a.add(MeshAcc.cyl(0.1, 0.4, -1.0, 10), MeshAcc.xf(Vector3(sx, 1.4, -0.55)), GREY)
				a.add(MeshAcc.cyl(0.11, 0.04, -1.0, 10), MeshAcc.xf(Vector3(sx, 1.6, -0.55)), DARK)
			# yellow crane rail on the roof
			for p in [[Vector3(-0.6, 1.2, 0.25), Vector3(-0.6, 1.55, 0.25)], [Vector3(0.6, 1.2, 0.25), Vector3(0.6, 1.55, 0.25)], [Vector3(-0.6, 1.55, 0.25), Vector3(0.6, 1.55, 0.25)], [Vector3(0.6, 1.55, 0.25), Vector3(0.6, 1.55, -0.25)]]:
				a.add(MeshAcc.cyl(0.025, 1.0, -1.0, 6), MeshAcc.limb(p[0], p[1]), YEL)
			_crate(a, Vector3(-0.72, 0.13, 0.75), Vector3(0.26, 0.24, 0.24), YEL.darkened(0.2), 6.0)
			_crate(a, Vector3(-0.46, 0.13, 0.8), Vector3(0.22, 0.18, 0.2), GREY, -10.0)
			_bb(a, Vector3(0.2, 0.2, 0.03), Vector3(0.62, 0.25, 0.8), YEL, 0.01, Vector3(0, -15, 0))
			_box(a, Vector3(0.18, 0.04, 0.035), Vector3(0.62, 0.25, 0.8), BLK, Vector3(0, -15, 45))
			_box(a, Vector3(0.18, 0.04, 0.035), Vector3(0.62, 0.25, 0.8), BLK, Vector3(0, -15, -45))
		"armory":
			_pad(a, S)
			_bb(a, Vector3(1.7, 0.75, 1.4), Vector3(0, 0.5, -0.15), DARK, 0.05)
			_bb(a, Vector3(1.82, 0.12, 1.52), Vector3(0, 0.93, -0.15), MIDG, 0.04)
			_bb(a, Vector3(0.5, 0.08, 0.4), Vector3(0.2, 1.02, -0.3), GREY, 0.02)
			_bb(a, Vector3(1.72, 0.08, 1.42), Vector3(0, 0.74, -0.15), RED_S, 0.015)
			_door(a, Vector3(0.0, 0.13, 0.565), 0.34, 0.45)
			_bb(a, Vector3(0.3, 0.3, 0.03), Vector3(0.52, 0.45, 0.565), BLK, 0.01)
			_icon_bullets(a, Vector3(0.52, 0.45, 0.585), 0.24, LAMP_O)
			_crate(a, Vector3(-0.66, 0.13, 0.72), Vector3(0.26, 0.2, 0.22), OLIVE, 6.0)
			_crate(a, Vector3(-0.4, 0.13, 0.74), Vector3(0.24, 0.2, 0.22), OLIVE, -8.0)
			_crate(a, Vector3(-0.54, 0.33, 0.72), Vector3(0.24, 0.18, 0.2), OLIVE, 12.0)
			_barrel(a, Vector3(0.72, 0.13, 0.75), RED)
		"medbay":
			_pad(a, S)
			_bb(a, Vector3(1.6, 0.82, 1.35), Vector3(0, 0.54, -0.15), WHITE, 0.05)
			_bb(a, Vector3(1.64, 0.1, 1.39), Vector3(0, 0.18, -0.15), GRN, 0.02)
			_bb(a, Vector3(1.66, 0.09, 1.41), Vector3(0, 0.98, -0.15), OFFW, 0.03)
			_bb(a, Vector3(0.95, 0.12, 0.75), Vector3(0.1, 1.06, -0.2), WHITE, 0.03)
			a.add(MeshAcc.cyl(0.3, 0.025, -1.0, 20), MeshAcc.xf(Vector3(0.1, 1.135, -0.2)), DARK)
			_icon_cross(a, Vector3(0.1, 1.15, -0.2), 0.36, Color(0.2, 0.95, 0.3, 0.05), true)
			_bb(a, Vector3(0.52, 0.52, 0.03), Vector3(-0.35, 0.55, 0.535), Color("2f5a33"), 0.012)
			_bb(a, Vector3(0.44, 0.44, 0.02), Vector3(-0.35, 0.55, 0.548), Color("8f938d"), 0.01)
			_icon_cross(a, Vector3(-0.35, 0.55, 0.566), 0.36, Color(0.22, 0.9, 0.3, 0.45))
			for k in 2:
				_win(a, Vector3(0.25 + k * 0.3, 0.68, 0.535), 0.18, 0.13)
			_win(a, Vector3(0.81, 0.6, -0.4), 0.3, 0.14, true)
			_door(a, Vector3(0.4, 0.13, 0.535), 0.22, 0.36, LAMP_B)
			_antenna(a, Vector3(0.62, 1.03, -0.62), 0.7)
			_antenna(a, Vector3(0.72, 1.03, -0.45), 0.55)
			_crate(a, Vector3(-0.66, 0.13, 0.75), Vector3(0.24, 0.16, 0.2), Color("dcd6a0"), 8.0)
		_:
			_pad(a, S)
			_bb(a, Vector3(S * 0.8, 0.8, S * 0.8), Vector3(0, 0.5, 0), OFFW, 0.05)
	root.add_child(_mi(a))
	if id == "fabricator":
		_light(root, Vector3(-0.25, 0.5, 0.9), Color(0.35, 0.6, 1.0), 2.2, 0.7)
	elif id == "bio_refinery":
		_light(root, Vector3(0.4, 0.35, 0.95), Color(1.0, 0.5, 0.12), 2.2, 0.8)
	elif id == "mining_rig":
		_light(root, Vector3(0, 0.6, 0), Color(0.3, 1.0, 0.85), 3.0, 0.8)
	elif id == "medbay":
		_light(root, Vector3(-0.35, 0.55, 0.85), Color(0.3, 1.0, 0.4), 2.0, 0.5)
	elif id == "armory":
		_light(root, Vector3(0.3, 0.5, 0.85), Color(1.0, 0.55, 0.2), 1.8, 0.5)


## Harvester drone: white bevelled body, four arms with guarded rotors, blue
## underglow, skids and a claw.
static func drone_mesh() -> ArrayMesh:
	var a := MeshAcc.new()
	_bb(a, Vector3(0.34, 0.14, 0.3), Vector3.ZERO, WHITE, 0.035)
	_bb(a, Vector3(0.2, 0.07, 0.18), Vector3(0, 0.09, -0.02), DARK, 0.02)
	_box(a, Vector3(0.1, 0.05, 0.02), Vector3(0, 0.0, 0.155), WIN_L)
	_box(a, Vector3(0.22, 0.012, 0.2), Vector3(0, -0.075, 0), LAMP_B)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var tip := Vector3(sx * 0.36, 0.04, sz * 0.3)
			a.add(MeshAcc.cyl(0.018, 1.0, -1.0, 5), MeshAcc.limb(Vector3(sx * 0.12, 0.02, sz * 0.1), tip), DARK)
			a.add(MeshAcc.cyl(0.035, 0.07, -1.0, 8), MeshAcc.xf(tip + Vector3(0, 0.02, 0)), MIDG)
			a.add(MeshAcc.cyl(0.12, 0.008, -1.0, 12), MeshAcc.xf(tip + Vector3(0, 0.06, 0)), Color(0.2, 0.2, 0.2))
			for k in 8:
				var a0 := TAU * k / 8.0
				var a1 := TAU * (k + 1) / 8.0
				a.add(MeshAcc.cyl(0.008, 1.0, -1.0, 4), MeshAcc.limb(tip + Vector3(cos(a0) * 0.14, 0.06, sin(a0) * 0.14), tip + Vector3(cos(a1) * 0.14, 0.06, sin(a1) * 0.14)), WHITE)
	for sx: float in [-1.0, 1.0]:
		a.add(MeshAcc.cyl(0.01, 1.0, -1.0, 4), MeshAcc.limb(Vector3(sx * 0.1, -0.07, 0), Vector3(sx * 0.13, -0.16, 0)), DARK)
		_box(a, Vector3(0.02, 0.02, 0.26), Vector3(sx * 0.13, -0.165, 0), DARK)
	_box(a, Vector3(0.02, 0.16, 0.02), Vector3(0, -0.16, 0), BLK)
	for sx: float in [-1.0, 1.0]:
		_box(a, Vector3(0.02, 0.1, 0.02), Vector3(sx * 0.04, -0.27, 0), BLK, Vector3(0, 0, sx * 25.0))
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


