class_name TurretModels
extends RefCounted
## Placeholder low-poly turret models from primitives. Every turret shares a
## steel base striped in its damage-type colour; the head (child "Head")
## rotates to aim, with the barrel along +Z. "Muzzle" marks the shot origin.


static func mat(col: Color, glow := 0.0, metal := 0.4) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = metal
	m.roughness = 0.5
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = glow
	return m


static func part(parent: Node3D, mesh: Mesh, m: Material, pos: Vector3, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi


static func box(x: float, y: float, z: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(x, y, z)
	return b


static func cyl(r: float, hgt: float, top := -1.0, seg := 8) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.bottom_radius = r
	c.top_radius = r if top < 0.0 else top
	c.height = hgt
	c.radial_segments = seg
	c.rings = 0
	return c


## Builds the model under `root`; returns [base_material, head, muzzle].
static func build(root: Node3D, id: String, accent: Color) -> Array:
	var steel := mat(Color(0.78, 0.77, 0.72), 0.0, 0.3)           # off-white composite body
	var base_mat := mat(Color(0.45, 0.46, 0.46), 0.0, 0.5)        # worn grey mount (damage tint)
	var acc := mat(accent, 0.6, 0.2)
	var dark := mat(Color(0.12, 0.13, 0.14), 0.0, 0.7)
	var hazard := mat(Color(0.95, 0.78, 0.12), 0.0, 0.2)
	# round mounting pad on four struts, accent ring, hazard collar
	part(root, cyl(0.5, 0.12, 0.48, 12), dark, Vector3(0, 0.06, 0))
	for k in 4:
		var ang := k * PI * 0.5 + PI * 0.25
		part(root, box(0.1, 0.35, 0.1), base_mat, Vector3(cos(ang) * 0.32, 0.25, sin(ang) * 0.32))
	part(root, cyl(0.42, 0.22, 0.38, 12), base_mat, Vector3(0, 0.3, 0))
	part(root, cyl(0.44, 0.06, -1.0, 12), acc, Vector3(0, 0.43, 0))
	part(root, cyl(0.3, 0.06, -1.0, 12), hazard, Vector3(0, 0.48, 0))
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 0.55, 0)
	root.add_child(head)
	var muzzle := Node3D.new()
	muzzle.name = "Muzzle"
	head.add_child(muzzle)
	# damage-type accent stripe on every head
	part(head, box(0.5, 0.06, 0.5), acc, Vector3(0, 0.03, 0))
	match id:
		"autocannon":
			part(head, box(0.55, 0.35, 0.6), steel, Vector3(0, 0.2, 0))
			for sx in [-0.12, 0.12]:
				part(head, cyl(0.06, 0.9), dark, Vector3(sx, 0.22, 0.65), Vector3(90, 0, 0))
			part(head, box(0.56, 0.06, 0.2), acc, Vector3(0, 0.4, -0.1))
			muzzle.position = Vector3(0, 0.22, 1.1)
		"flamethrower":
			part(head, cyl(0.22, 0.6), mat(Color(0.75, 0.25, 0.08), 0.0, 0.3), Vector3(0, 0.3, -0.15))
			part(head, cyl(0.08, 0.7, 0.16), dark, Vector3(0, 0.3, 0.45), Vector3(90, 0, 0))
			part(head, cyl(0.17, 0.06), acc, Vector3(0, 0.3, 0.82), Vector3(90, 0, 0))
			muzzle.position = Vector3(0, 0.3, 0.85)
		"railgun":
			part(head, box(0.4, 0.3, 0.5), steel, Vector3(0, 0.2, -0.1))
			for sx in [-0.1, 0.1]:
				part(head, box(0.05, 0.12, 1.6), steel, Vector3(sx, 0.25, 0.75))
			part(head, box(0.12, 0.05, 1.4), acc, Vector3(0, 0.25, 0.7))
			muzzle.position = Vector3(0, 0.25, 1.55)
		"shock_grid":
			part(head, cyl(0.2, 0.9), steel, Vector3(0, 0.45, 0))
			for k in 3:
				part(head, cyl(0.3 - k * 0.05, 0.06), acc, Vector3(0, 0.2 + k * 0.3, 0))
			part(head, SphereMesh.new(), acc, Vector3(0, 1.05, 0)).scale = Vector3.ONE * 0.35
			muzzle.position = Vector3(0, 1.05, 0)
		"mortar":
			part(head, box(0.6, 0.25, 0.6), steel, Vector3(0, 0.12, 0))
			part(head, cyl(0.16, 0.9, 0.14), mat(Color(0.35, 0.4, 0.22), 0.0, 0.3), Vector3(0, 0.5, 0.15), Vector3(45, 0, 0))
			part(head, cyl(0.17, 0.06), acc, Vector3(0, 0.8, 0.45), Vector3(45, 0, 0))
			muzzle.position = Vector3(0, 0.85, 0.48)
		"seismic_spike":
			part(head, cyl(0.32, 0.25), steel, Vector3(0, 0.12, 0))
			part(head, cyl(0.16, 0.9), mat(Color(0.5, 0.36, 0.22), 0.0, 0.4), Vector3(0, 0.7, 0))
			part(head, cyl(0.26, 0.3), acc, Vector3(0, 1.2, 0))
			muzzle.position = Vector3(0, 0.0, 0)
	return [base_mat, head, muzzle]


## Tier II/III armour: extra plating on the head (scale +10%/tier is applied
## by the Turret itself).
static func set_tier_armor(head: Node3D, tier: int) -> void:
	var old := head.get_node_or_null("Armor")
	if old:
		old.queue_free()
	if tier <= 1:
		return
	var arm := Node3D.new()
	arm.name = "Armor"
	head.add_child(arm)
	var m := mat(Color(0.36, 0.37, 0.37), 0.0, 0.6)
	var y := mat(Color(0.95, 0.78, 0.12), 0.0, 0.2)
	for sx in [-1.0, 1.0]:
		part(arm, box(0.08, 0.32, 0.5), m, Vector3(sx * 0.33, 0.22, 0.0))
		if tier >= 3:
			part(arm, box(0.1, 0.1, 0.5), y, Vector3(sx * 0.36, 0.42, 0.0))
	if tier >= 3:
		part(arm, box(0.6, 0.06, 0.3), m, Vector3(0, 0.45, -0.15))


## Tier pips on a turret base: one bar per tier above I.
static func set_tier_pips(root: Node3D, tier: int, accent: Color) -> void:
	var old := root.get_node_or_null("Pips")
	if old:
		old.queue_free()
	var pips := Node3D.new()
	pips.name = "Pips"
	root.add_child(pips)
	var m := mat(accent, 2.0, 0.0)
	for k in tier - 1:
		part(pips, box(0.7, 0.05, 0.08), m, Vector3(0, 0.47, -0.3 + k * 0.14))
