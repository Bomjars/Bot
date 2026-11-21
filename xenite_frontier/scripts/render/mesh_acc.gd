class_name MeshAcc
extends RefCounted
## Accumulates transformed primitive meshes into one ArrayMesh with baked
## vertex colours. Optional per-vertex "part" id in UV.x (used by the alien
## shader to animate limbs) and faceted (flat-shaded) output.

var v := PackedVector3Array()
var n := PackedVector3Array()
var c := PackedColorArray()
var uv := PackedVector2Array()
var i := PackedInt32Array()


func add(mesh: Mesh, xf: Transform3D, col: Color, part := 0.0) -> void:
	var arr: Array
	if mesh is PrimitiveMesh:
		arr = (mesh as PrimitiveMesh).get_mesh_arrays()
	else:
		arr = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var ind: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var base := v.size()
	var nb := xf.basis.inverse().transposed()
	for k in verts.size():
		v.append(xf * verts[k])
		n.append((nb * norms[k]).normalized())
		c.append(col)
		uv.append(Vector2(part, 0.0))
	for k in ind.size():
		i.append(ind[k] + base)


## Displaces every vertex added so far from index `from` with noise (rocks).
func jitter(from: int, amount: float, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var cache := {}
	for k in range(from, v.size()):
		var key := Vector3i(v[k] * 100.0)
		if not cache.has(key):
			cache[key] = Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * amount
		v[k] += cache[key]


func commit(flat := false) -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	if flat:
		# un-index and use face normals: crisp low-poly facets
		var fv := PackedVector3Array()
		var fn := PackedVector3Array()
		var fc := PackedColorArray()
		var fu := PackedVector2Array()
		for t in range(0, i.size(), 3):
			var a := v[i[t]]
			var b := v[i[t + 1]]
			var d := v[i[t + 2]]
			var nrm := (d - a).cross(b - a).normalized()
			for k in 3:
				fv.append(v[i[t + k]])
				fn.append(nrm)
				fc.append(c[i[t + k]])
				fu.append(uv[i[t + k]])
		arr[Mesh.ARRAY_VERTEX] = fv
		arr[Mesh.ARRAY_NORMAL] = fn
		arr[Mesh.ARRAY_COLOR] = fc
		arr[Mesh.ARRAY_TEX_UV] = fu
	else:
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_INDEX] = i
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


# ------------------------------------------------------------ primitives

static func box(x: float, y: float, z: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(x, y, z)
	return b


static func cyl(r: float, hgt: float, top := -1.0, seg := 8) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r
	cm.top_radius = r if top < 0.0 else top
	cm.height = hgt
	cm.radial_segments = seg
	cm.rings = 0
	return cm


static func ball(r: float, seg := 8, rings := 5) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = seg
	s.rings = rings
	return s


static func dome(r: float, hgt: float, seg := 12, rings := 4) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = hgt
	s.is_hemisphere = true
	s.radial_segments = seg
	s.rings = rings
	return s


static func capsule(r: float, hgt: float, seg := 6, rings := 1) -> CapsuleMesh:
	var cp := CapsuleMesh.new()
	cp.radius = r
	cp.height = maxf(hgt, r * 2.0 + 0.001)
	cp.radial_segments = seg
	cp.rings = rings
	return cp


static func cone(r: float, hgt: float, seg := 5) -> CylinderMesh:
	return cyl(r, hgt, 0.0, seg)


static func xf(pos: Vector3, rot_deg := Vector3.ZERO, scl := Vector3.ONE) -> Transform3D:
	return Transform3D(Basis.from_euler(rot_deg * (PI / 180.0)).scaled(scl), pos)


## Transform that places a primitive (built along +Y) as a limb from a to b.
static func limb(a: Vector3, b: Vector3, thick := Vector3.ONE) -> Transform3D:
	var d := b - a
	var l := d.length()
	var y := d / maxf(l, 0.0001)
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y)
	return Transform3D(Basis(x * thick.x, y * l, z * thick.z), (a + b) * 0.5)
