class_name AlienMeshes
extends RefCounted
## Procedural low-poly predator silhouettes built from primitives with baked
## vertex colours. Every model faces +Z, feet on y = 0, so one transform per
## instance is enough. Each strain is readable by shape AND colour:
##   Stalker   - low, long, bone-yellow, spined, red maw
##   Mauler    - hulking rust-red block with huge forearms and grey plates
##   Spitter   - thin grey body under a glowing green acid sac
##   Snatcher  - tall violet stick-thing with long hooked arms
##   Burrower  - flat orange segmented grub with a steel drill head
##   Brood Mother - huge crimson-magenta bloated abdomen with a bone crown

const GLOW := 0.0  # vertex alpha for emissive parts


class Acc:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var i := PackedInt32Array()

	func add(mesh: PrimitiveMesh, xf: Transform3D, col: Color) -> void:
		var arr := mesh.get_mesh_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var ind: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var base := v.size()
		var nb := xf.basis.inverse().transposed()
		for k in verts.size():
			v.append(xf * verts[k])
			n.append((nb * norms[k]).normalized())
			c.append(col)
		for k in ind.size():
			i.append(ind[k] + base)

	func commit() -> ArrayMesh:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_INDEX] = i
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		return m


static func box(sx: float, sy: float, sz: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(sx, sy, sz)
	return b


static func cone(r: float, hgt: float, seg := 5) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = 0.0
	c.bottom_radius = r
	c.height = hgt
	c.radial_segments = seg
	c.rings = 0
	c.cap_top = false
	return c


static func ball(r: float, seg := 7, rings := 4) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = seg
	s.rings = rings
	return s


static func xf(pos: Vector3, rot_deg := Vector3.ZERO, scl := Vector3.ONE) -> Transform3D:
	var b := Basis.from_euler(rot_deg * (PI / 180.0)).scaled(scl)
	return Transform3D(b, pos)


static func build(id: String) -> ArrayMesh:
	var a := Acc.new()
	match id:
		"stalker": _stalker(a)
		"mauler": _mauler(a)
		"spitter": _spitter(a)
		"snatcher": _snatcher(a)
		"burrower": _burrower(a)
		"brood_mother": _brood_mother(a)
		_: a.add(box(0.5, 0.5, 0.5), xf(Vector3(0, 0.25, 0)), Color.MAGENTA)
	return a.commit()


static func _legs(a: Acc, count: int, spread_z: float, y: float, reach: float, thick: float, col: Color, z0 := 0.0) -> void:
	for k in count:
		var z := z0 + lerpf(-spread_z, spread_z, float(k) / max(1, count - 1))
		for side in [-1.0, 1.0]:
			a.add(box(thick, y * 1.25, thick), xf(Vector3(side * reach, y * 0.5, z), Vector3(0, 0, side * 28.0)), col)


static func _stalker(a: Acc) -> void:
	var bone := Color(0.86, 0.78, 0.46)
	var dark := Color(0.45, 0.38, 0.2)
	var maw := Color(0.9, 0.12, 0.1, 0.4)
	a.add(box(0.32, 0.22, 0.95), xf(Vector3(0, 0.38, 0), Vector3(-8, 0, 0)), bone)
	a.add(cone(0.17, 0.5), xf(Vector3(0, 0.36, 0.68), Vector3(90, 0, 0)), maw)
	a.add(cone(0.08, 0.8, 4), xf(Vector3(0, 0.34, -0.8), Vector3(-95, 0, 0)), dark)
	for k in 3:
		a.add(cone(0.06, 0.35, 4), xf(Vector3(0, 0.55, 0.25 - k * 0.25), Vector3(-30, 0, 0)), dark)
	_legs(a, 2, 0.3, 0.32, 0.22, 0.06, dark)


static func _mauler(a: Acc) -> void:
	var hide := Color(0.7, 0.14, 0.06)
	var plate := Color(0.32, 0.08, 0.05)
	var claw := Color(0.9, 0.85, 0.75)
	a.add(box(1.3, 0.9, 1.0), xf(Vector3(0, 1.05, -0.1), Vector3(12, 0, 0)), hide)
	a.add(box(1.5, 0.3, 0.8), xf(Vector3(0, 1.6, 0.0), Vector3(12, 0, 0)), plate)
	a.add(box(0.4, 0.35, 0.4), xf(Vector3(0, 0.85, 0.55)), plate)
	for side in [-1.0, 1.0]:
		a.add(box(0.42, 1.1, 0.42), xf(Vector3(side * 0.85, 0.65, 0.45), Vector3(25, 0, 0)), hide)
		a.add(box(0.55, 0.35, 0.55), xf(Vector3(side * 0.85, 0.18, 0.75)), plate)
		a.add(cone(0.1, 0.4, 4), xf(Vector3(side * 0.85, 0.18, 1.1), Vector3(90, 0, 0)), claw)
		a.add(box(0.35, 0.7, 0.35), xf(Vector3(side * 0.4, 0.35, -0.45)), hide)


static func _spitter(a: Acc) -> void:
	var skin := Color(0.38, 0.36, 0.42)
	var acid := Color(0.45, 1.0, 0.2, GLOW)
	a.add(box(0.36, 0.26, 0.7), xf(Vector3(0, 0.45, 0)), skin)
	a.add(ball(0.42), xf(Vector3(0, 0.85, -0.25), Vector3.ZERO, Vector3(1, 0.85, 1.1)), acid)
	a.add(box(0.12, 0.12, 0.55), xf(Vector3(0, 0.7, 0.45), Vector3(-40, 0, 0)), skin)
	a.add(ball(0.14, 6, 3), xf(Vector3(0, 0.9, 0.68)), acid)
	_legs(a, 3, 0.25, 0.42, 0.26, 0.05, skin)


static func _snatcher(a: Acc) -> void:
	var violet := Color(0.5, 0.22, 0.82)
	var dark := Color(0.22, 0.1, 0.35)
	var hook := Color(0.95, 0.9, 1.0)
	a.add(box(0.28, 1.1, 0.3), xf(Vector3(0, 1.25, 0.1), Vector3(22, 0, 0)), violet)
	a.add(cone(0.16, 0.45, 4), xf(Vector3(0, 1.85, 0.45), Vector3(70, 0, 0)), dark)
	for side in [-1.0, 1.0]:
		a.add(box(0.07, 0.07, 1.2), xf(Vector3(side * 0.25, 1.35, 0.75), Vector3(15, side * 8.0, 0)), violet)
		a.add(cone(0.06, 0.35, 4), xf(Vector3(side * 0.3, 1.1, 1.38), Vector3(150, 0, 0)), hook)
		a.add(box(0.08, 1.0, 0.08), xf(Vector3(side * 0.22, 0.45, -0.05), Vector3(-8, 0, side * 12.0)), dark)


static func _burrower(a: Acc) -> void:
	var sand := Color(0.92, 0.55, 0.14)
	var band := Color(0.6, 0.32, 0.08)
	var drill := Color(0.6, 0.62, 0.66)
	for k in 3:
		var s := 1.0 - k * 0.18
		a.add(ball(0.38 * s), xf(Vector3(0, 0.26, -k * 0.5), Vector3.ZERO, Vector3(1.25, 0.6, 1.0)), sand if k % 2 == 0 else band)
	a.add(cone(0.34, 0.6, 6), xf(Vector3(0, 0.27, 0.5), Vector3(90, 0, 0)), drill)
	_legs(a, 3, 0.5, 0.18, 0.4, 0.06, band, -0.5)


static func _brood_mother(a: Acc) -> void:
	var flesh := Color(0.82, 0.1, 0.42)
	var dark := Color(0.35, 0.05, 0.18)
	var bone := Color(0.92, 0.88, 0.78)
	var eggs := Color(1.0, 0.55, 0.85, GLOW)
	a.add(ball(1.5, 9, 5), xf(Vector3(0, 1.6, -1.0), Vector3.ZERO, Vector3(1.1, 0.85, 1.35)), flesh)
	a.add(ball(0.5, 6, 3), xf(Vector3(0.6, 2.3, -1.4)), eggs)
	a.add(ball(0.4, 6, 3), xf(Vector3(-0.7, 2.0, -0.6)), eggs)
	a.add(box(1.0, 0.8, 1.2), xf(Vector3(0, 1.4, 0.8), Vector3(-10, 0, 0)), dark)
	a.add(box(0.7, 0.55, 0.6), xf(Vector3(0, 1.4, 1.6)), flesh)
	for k in 5:
		var ang := -50.0 + k * 25.0
		a.add(cone(0.12, 0.9, 4), xf(Vector3(sin(deg_to_rad(ang)) * 0.4, 1.95, 1.5), Vector3(-20, 0, -ang)), bone)
	_legs(a, 4, 1.1, 1.0, 1.0, 0.16, dark, 0.2)
