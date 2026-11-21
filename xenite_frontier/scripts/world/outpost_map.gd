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
var colonist_at := PackedInt32Array() # exposed colonist id + 1 standing in the cell (0 = none)
var crew_at := PackedInt32Array()     # turret cell: crew colonist id + 1 (Snatchers can pull them out)
var corpse_count := PackedInt32Array() # corpses (alien + human) in the cell - feeding reads this
var goal_cells := PackedInt32Array()
var spawn_cells := PackedInt32Array()
var core_center := Vector3.ZERO
var initial_structures: Array = []   # [cell, "wall"|"blast_door"|turret id]

var climb_height := 1.6
var max_pile := 2.6

var _ground: MeshInstance3D
var _heat: MeshInstance3D
var _terrain: MeshInstance3D
var terrain_material: ShaderMaterial

## Terrain heightfield at half-cell resolution: vertex (i, j) sits at world
## (origin.x + i * 0.5, origin.y + j * 0.5). Rock cells rise into cliffs,
## walkable ground is gently uneven with craters; the base pad is levelled.
var hgrid := PackedFloat32Array()
var hw := 0
var hh := 0


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
	for a in [colonist_at, crew_at, corpse_count]:
		a.resize(n)
		a.fill(0)
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
	_build_heights(seed_value, core)

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


# ---------------------------------------------------------------- terrain

## Ground height (bilinear over the heightfield) at world (x, z).
func height_at(x: float, z: float) -> float:
	var fx := clampf((x - origin.x) * 2.0, 0.0, hw - 1.001)
	var fz := clampf((z - origin.y) * 2.0, 0.0, hh - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var k := j * hw + i
	var a := lerpf(hgrid[k], hgrid[k + 1], tx)
	var b := lerpf(hgrid[k + hw], hgrid[k + hw + 1], tx)
	return lerpf(a, b, tz)


func cell_height(c: int) -> float:
	var p := cell_center(c)
	return height_at(p.x, p.z)


## World position of a cell centre standing on the terrain.
func cell_ground(c: int) -> Vector3:
	var p := cell_center(c)
	p.y = height_at(p.x, p.z)
	return p


func _build_heights(seed_value: int, core: Vector2i) -> void:
	hw = 2 * w + 1
	hh = 2 * h + 1
	hgrid.resize(hw * hh)
	var n_ground := FastNoiseLite.new()
	n_ground.seed = seed_value + 11
	n_ground.frequency = 0.035
	n_ground.fractal_octaves = 3
	var n_rock := FastNoiseLite.new()
	n_rock.seed = seed_value + 23
	n_rock.frequency = 0.07
	n_rock.fractal_octaves = 2
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 5
	# craters: bowl + raised rim, kept off the base pad
	var craters: Array[Vector3] = []
	var core_w := Vector2(origin.x + core.x + 0.5, origin.y + core.y + 0.5)
	for k in 60:
		var cx := rng.randf_range(origin.x + 6, origin.x + w - 6)
		var cz := rng.randf_range(origin.y + 6, origin.y + h - 6)
		if Vector2(cx, cz).distance_to(core_w) < 26.0:
			continue
		craters.append(Vector3(cx, cz, rng.randf_range(1.5, 5.5)))
	var rock_h := PackedFloat32Array()
	rock_h.resize(w * h)
	for c in w * h:
		var p := cell_center(c)
		rock_h[c] = 3.2 + (n_rock.get_noise_2d(p.x, p.z) * 0.5 + 0.5) * 3.2
	for j in hh:
		for i in hw:
			var wx := origin.x + i * 0.5
			var wz := origin.y + j * 0.5
			# cells sharing this vertex
			var xs: Array[int] = []
			var zs: Array[int] = []
			if i % 2 == 1:
				xs.append((i - 1) / 2)
			else:
				xs.append(i / 2 - 1)
				xs.append(i / 2)
			if j % 2 == 1:
				zs.append((j - 1) / 2)
			else:
				zs.append(j / 2 - 1)
				zs.append(j / 2)
			var all_rock := true
			var any_rock := false
			var rsum := 0.0
			var rn := 0
			for cz in zs:
				for cx in xs:
					if not in_bounds(cx, cz):
						continue
					var c := idx(cx, cz)
					if kind[c] == Kind.ROCK:
						any_rock = true
						rsum += rock_h[c]
						rn += 1
					else:
						all_rock = false
			var hgt: float
			if all_rock and rn > 0:
				hgt = rsum / rn
			else:
				hgt = (n_ground.get_noise_2d(wx, wz) * 0.5 + 0.5) * 0.9
				hgt += n_rock.get_noise_2d(wx * 3.1, wz * 3.1) * 0.22   # lumpy, uneven regolith
				for cr in craters:
					var d := Vector2(wx - cr.x, wz - cr.y).length() / cr.z
					if d < 1.25:
						# bowl inside, rim just outside the radius
						hgt += -0.55 * cr.z * 0.25 * maxf(0.0, 1.0 - d * d) + 0.25 * exp(-pow((d - 1.0) * 5.0, 2.0))
				if any_rock:
					hgt += 0.35  # rubble at the cliff foot
				# levelled base pad around the outpost
				var dc := Vector2(wx, wz).distance_to(core_w)
				hgt = lerpf(0.12, hgt, smoothstep(17.0, 24.0, dc))
			hgrid[j * hw + i] = hgt


func _build_terrain_mesh() -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idxs := PackedInt32Array()
	verts.resize(hw * hh)
	norms.resize(hw * hh)
	uvs.resize(hw * hh)
	for j in hh:
		for i in hw:
			var k := j * hw + i
			verts[k] = Vector3(origin.x + i * 0.5, hgrid[k], origin.y + j * 0.5)
			var hl := hgrid[k - 1] if i > 0 else hgrid[k]
			var hr := hgrid[k + 1] if i < hw - 1 else hgrid[k]
			var hu := hgrid[k - hw] if j > 0 else hgrid[k]
			var hd := hgrid[k + hw] if j < hh - 1 else hgrid[k]
			norms[k] = Vector3(hl - hr, 1.0, hu - hd).normalized()
			uvs[k] = Vector2(i * 0.5, j * 0.5)
	idxs.resize((hw - 1) * (hh - 1) * 6)
	var t := 0
	for j in hh - 1:
		for i in hw - 1:
			var a := j * hw + i
			var b := a + 1
			var c := a + hw
			var d := c + 1
			# split quads along the shorter diagonal for nicer cliffs
			if absf(hgrid[a] - hgrid[d]) < absf(hgrid[b] - hgrid[c]):
				idxs[t] = a; idxs[t + 1] = b; idxs[t + 2] = d
				idxs[t + 3] = a; idxs[t + 4] = d; idxs[t + 5] = c
			else:
				idxs[t] = a; idxs[t + 1] = b; idxs[t + 2] = c
				idxs[t + 3] = b; idxs[t + 4] = d; idxs[t + 5] = c
			t += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_terrain = MeshInstance3D.new()
	_terrain.name = "Terrain"
	_terrain.mesh = mesh
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = preload("res://scripts/render/terrain.gdshader")
	_terrain.material_override = terrain_material
	add_child(_terrain)


## Build-grid overlay strength (brighter while a build tool is selected).
func set_grid_visible(on: bool) -> void:
	if terrain_material:
		terrain_material.set_shader_parameter("grid_strength", 0.35 if on else 0.0)


## Scattered boulders at cliff feet and glowing Xenite crystal clusters on
## the plateaus. Purely visual.
func _build_scatter(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 99
	var boulders: Array[Transform3D] = []
	var crystals: Array[Transform3D] = []
	for c in w * h:
		var x := c % w
		var z := c / w
		if x < 1 or z < 1 or x >= w - 1 or z >= h - 1:
			continue
		var near_rock := kind[c - 1] == Kind.ROCK or kind[c + 1] == Kind.ROCK or kind[c - w] == Kind.ROCK or kind[c + w] == Kind.ROCK
		if kind[c] == Kind.GROUND:
			var chance := 0.22 if near_rock else 0.012
			if is_goal(c) or cell_center(c).distance_to(core_center) < 20.0:
				chance = 0.0
			if rng.randf() < chance:
				var p := cell_center(c) + Vector3(rng.randf_range(-0.4, 0.4), 0, rng.randf_range(-0.4, 0.4))
				p.y = height_at(p.x, p.z) - 0.05
				var sc := rng.randf_range(0.18, 0.55) * (1.4 if near_rock else 1.0)
				var b := Basis.from_euler(Vector3(rng.randf() * 0.6, rng.randf() * TAU, rng.randf() * 0.6)).scaled(Vector3(sc * rng.randf_range(0.8, 1.4), sc * rng.randf_range(0.5, 0.9), sc))
				boulders.append(Transform3D(b, p))
		elif kind[c] == Kind.ROCK and near_rock and rng.randf() < 0.05:
			var p := cell_center(c)
			p.y = height_at(p.x, p.z) - 0.1
			var sc := rng.randf_range(0.5, 1.1)
			crystals.append(Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3.ONE * sc), p))
	_scatter_mmi(StationModels.boulder_mesh(), boulders, StationModels.rock_material())
	_scatter_mmi(StationModels.crystal_mesh(), crystals, StationModels.crystal_material())


func _scatter_mmi(mesh: Mesh, xfs: Array[Transform3D], mat: Material) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)


# ---------------------------------------------------------------- visuals

func _build_visuals() -> void:
	_build_terrain_mesh()
	_build_scatter(int(GameConfig.section("test_range").get("seed", 1337)))
	var core := Node3D.new()
	core.name = "HabDome"
	core.position = cell_ground(idx(int(core_center.x - origin.x), int(core_center.z - origin.y)))
	add_child(core)
	StationModels.build_hab_dome(core)
	_place_props()


## A few Mars-base props (solar arrays, tanks, comms towers) on the rock
## plateaus overlooking the outpost.
func _place_props() -> void:
	var placed: Array[Vector3] = []
	var k := 0
	for c in w * h:
		if placed.size() >= 7:
			break
		var x := c % w
		var z := c / w
		if x < 3 or z < 3 or x >= w - 3 or z >= h - 3 or kind[c] != Kind.ROCK:
			continue
		var p := cell_ground(c)
		var d := p.distance_to(core_center)
		if d < 22.0 or d > 45.0:
			continue
		var solid := true
		for oz in range(-2, 3):
			for ox in range(-2, 3):
				if kind[idx(x + ox, z + oz)] != Kind.ROCK:
					solid = false
		if not solid:
			continue
		var far := true
		for q in placed:
			if q.distance_to(p) < 8.0:
				far = false
		if not far:
			continue
		var prop := StationModels.plateau_prop(k)
		prop.position = p
		prop.rotation.y = float(k) * 1.3
		add_child(prop)
		placed.append(p)
		k += 1


## Debug overlay: colours each cell by flow-field distance to the core.
func show_heatmap(field: FlowField, visible_on: bool) -> void:
	if _heat == null:
		_heat = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(w, h)
		_heat.mesh = pm
		_heat.position = Vector3(origin.x + w * 0.5, 0.9, origin.y + h * 0.5)
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
