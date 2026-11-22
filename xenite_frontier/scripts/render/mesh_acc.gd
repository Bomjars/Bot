class_name MeshAcc
extends RefCounted
## Accumulates transformed primitive meshes into one ArrayMesh with baked
## vertex colours. Optional per-vertex "part" id in UV.x (used by the alien
## shader to animate limbs) and faceted (flat-shaded) output.

var v := PackedVector3Array()
var n := PackedVector3Array()
var c := PackedColorArray()
var uv := PackedVector2Array()
var uv2 := PackedVector2Array()
var i := PackedInt32Array()


## part: animation part id (UV.x); off: phase offset (UV.y); pivot: joint
## (y, z) in model space (UV2) - see alien.gdshader.
func add(mesh: Mesh, xf: Transform3D, col: Color, part := 0.0, off := 0.0, pivot := Vector2.ZERO) -> void:
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
		uv.append(Vector2(part, off))
		uv2.append(pivot)
	for k in ind.size():
		i.append(ind[k] + base)


## A box with chamfered (bevelled) edges and corners: the chunky look of the
## outpost buildings. Bevels catch highlights, so shapes read from far away.
func add_bevel_box(size: Vector3, xform: Transform3D, col: Color, bevel := 0.04, part := 0.0, off := 0.0, pivot := Vector2.ZERO) -> void:
	var h := size * 0.5
	var b := minf(bevel, minf(h.x, minf(h.y, h.z)) * 0.9)
	var polys: Array = []
	for ax in 3:
		for sg: float in [-1.0, 1.0]:
			# main face
			var q: Array = []
			for u: float in [-1.0, 1.0]:
				for w: float in [-1.0, 1.0]:
					q.append(_bv(ax, sg, u, w, h, b))
			polys.append([q[0], q[1], q[3], q[2]])
	# 12 edge chamfers
	for a1 in 3:
		for a2 in range(a1 + 1, 3):
			var a3 := 3 - a1 - a2
			for s1: float in [-1.0, 1.0]:
				for s2: float in [-1.0, 1.0]:
					var pts: Array = []
					for s3: float in [-1.0, 1.0]:
						var p1 := Vector3.ZERO
						p1[a1] = s1 * h[a1]
						p1[a2] = s2 * (h[a2] - b)
						p1[a3] = s3 * (h[a3] - b)
						var p2 := Vector3.ZERO
						p2[a1] = s1 * (h[a1] - b)
						p2[a2] = s2 * h[a2]
						p2[a3] = s3 * (h[a3] - b)
						pts.append(p1)
						pts.append(p2)
					polys.append([pts[0], pts[1], pts[3], pts[2]])
	# 8 corner triangles
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				polys.append([Vector3(sx * h.x, sy * (h.y - b), sz * (h.z - b)), Vector3(sx * (h.x - b), sy * h.y, sz * (h.z - b)), Vector3(sx * (h.x - b), sy * (h.y - b), sz * h.z)])
	var nb := xform.basis.inverse().transposed()
	for poly: Array in polys:
		var cen := Vector3.ZERO
		for pt: Vector3 in poly:
			cen += pt
		cen /= float(poly.size())
		# winding: (p2 - p0) x (p1 - p0) must point away from the centre
		var p0: Vector3 = poly[0]
		var nrm := ((poly[2] as Vector3) - p0).cross((poly[1] as Vector3) - p0)
		if nrm.dot(cen) < 0.0:
			poly.reverse()
			nrm = -nrm
		var base := v.size()
		for pt: Vector3 in poly:
			v.append(xform * pt)
			n.append((nb * nrm).normalized())
			c.append(col)
			uv.append(Vector2(part, off))
			uv2.append(pivot)
		for k in range(1, poly.size() - 1):
			i.append(base)
			i.append(base + k)
			i.append(base + k + 1)


static func _bv(ax: int, sg: float, u: float, w: float, h: Vector3, b: float) -> Vector3:
	var p := Vector3.ZERO
	p[ax] = sg * h[ax]
	var o1 := (ax + 1) % 3
	var o2 := (ax + 2) % 3
	p[o1] = u * (h[o1] - b)
	p[o2] = w * (h[o2] - b)
	return p


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
		var fu2 := PackedVector2Array()
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
				fu2.append(uv2[i[t + k]])
		arr[Mesh.ARRAY_VERTEX] = fv
		arr[Mesh.ARRAY_NORMAL] = fn
		arr[Mesh.ARRAY_COLOR] = fc
		arr[Mesh.ARRAY_TEX_UV] = fu
		arr[Mesh.ARRAY_TEX_UV2] = fu2
	else:
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_TEX_UV2] = uv2
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
