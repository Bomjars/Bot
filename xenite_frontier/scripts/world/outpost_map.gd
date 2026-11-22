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
enum SType { NONE = 0, WALL = 1, DOOR = 2, TURRET = 3, BAY = 4, LIGHT = 5, BUILDING = 6 }
const TERRAIN_LAYER := 1 << 10   # render layer only the terrain is on (ground decals)

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
var mouth_cells: Array[PackedInt32Array] = []   # spawn cells per canyon mouth
var core_center := Vector3.ZERO
var initial_structures: Array = []   # [cell, id] - classic layout (tests / --auto-land)
var default_site := Vector2i.ZERO    # suggested landing site (and the classic compound)
var base_cell := Vector2i(-1, -1)    # where the Command Hab landed (-1 = not yet)
var deposit := PackedByteArray()     # 1 = Xenite deposit (Mining Rigs build here)
var deposit_centers: Array[Vector2i] = []
var hbase := PackedFloat32Array()    # terrain before the landing pad was levelled

var climb_height := 1.6
var max_pile := 2.6

var _ground: MeshInstance3D
var _heat: MeshInstance3D
var _terrain: MeshInstance3D
var _dressing: Node3D
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


func has_base() -> bool:
	return base_cell.x >= 0


## Inside the Command Hab's 3x3 footprint.
func is_core(c: int) -> bool:
	if not has_base() or c < 0:
		return false
	return absi(c % w - base_cell.x) <= 1 and absi(c / w - base_cell.y) <= 1


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

	default_site = core
	core_center = cell_center(idx(core.x, core.y))
	goal_cells = PackedInt32Array()
	_build_heights(seed_value, core)
	_place_deposits(seed_value, mouths)

	spawn_cells = PackedInt32Array()
	mouth_cells.clear()
	for m: Vector2i in mouths:
		var mc := PackedInt32Array()
		for oz in range(-4, 5):
			for ox in range(-4, 5):
				var cx := clampi(m.x + ox, 0, w - 1)
				var cz := clampi(m.y + oz, 0, h - 1)
				if kind[idx(cx, cz)] == Kind.GROUND:
					spawn_cells.append(idx(cx, cz))
					mc.append(idx(cx, cz))
		mouth_cells.append(mc)
	_build_visuals()


## The classic walled compound (tests, benchmark, `--auto-land`): walls,
## doors, a small battery. Normal runs start empty after the landing.
func classic_layout() -> void:
	var core := base_cell
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
	put.call(core.x + 3, core.y + 3, "mortar")
	put.call(core.x - 9, core.y - 3, "floodlight")
	put.call(core.x + 9, core.y + 3, "floodlight")
	for c in planned:
		initial_structures.append([c, planned[c]])


# ---------------------------------------------------------------- landing

## Why the Command Hab can't land on `cell` ("" = it can). Needs a 7x7 patch
## of open ground, well away from the canyon mouths, reachable by the swarm.
func landing_problem(cell: Vector2i) -> String:
	if cell.x < 6 or cell.y < 6 or cell.x >= w - 6 or cell.y >= h - 6:
		return "Too close to the cliffs"
	for oz in range(-3, 4):
		for ox in range(-3, 4):
			var c := idx(cell.x + ox, cell.y + oz)
			if kind[c] != Kind.GROUND:
				return "Needs open, flat ground"
			if deposit[c]:
				return "Don't land on a Xenite deposit"
	for sc in spawn_cells:
		if Vector2(sc % w, sc / w).distance_to(Vector2(cell)) < 30.0:
			return "Too close to a canyon mouth"
	return ""


## Founds the outpost: goal cells, levelled pad, terrain/scatter rebuilt.
func set_base(cell: Vector2i) -> void:
	# a re-landing frees the previous hab's cells
	if base_cell.x >= 0:
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				_set_terrain(base_cell.x + ox, base_cell.y + oz, Kind.GROUND)
	base_cell = cell
	# the Command Hab is a solid 3x3 building; the swarm gnaws at its walls
	# from the ring of cells around it (the flow-field goal)
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			_set_terrain(cell.x + ox, cell.y + oz, Kind.ROCK)
	goal_cells = PackedInt32Array()
	for oz in range(-2, 3):
		for ox in range(-2, 3):
			if maxi(absi(ox), absi(oz)) == 2:
				goal_cells.append(idx(cell.x + ox, cell.y + oz))
	core_center = cell_center(idx(cell.x, cell.y))
	# level a pad around the landing site (blend into the raw terrain)
	var cw := Vector2(core_center.x, core_center.z)
	var pad := 0.0
	var pn := 0
	for j in hh:
		for i in hw:
			var wp := Vector2(origin.x + i * 0.5, origin.y + j * 0.5)
			var d := wp.distance_to(cw)
			var k := j * hw + i
			if d < 6.0:
				pad += hbase[k]
				pn += 1
	pad = pad / maxf(1, pn)
	for j in hh:
		for i in hw:
			var k := j * hw + i
			var wp := Vector2(origin.x + i * 0.5, origin.y + j * 0.5)
			var d := wp.distance_to(cw)
			if d > 26.0 or hbase[k] > 2.0:
				hgrid[k] = hbase[k]
			else:
				hgrid[k] = lerpf(pad, hbase[k], smoothstep(17.0, 24.0, d))
	(_terrain.mesh as ArrayMesh).clear_surfaces()
	_fill_terrain_mesh(_terrain.mesh as ArrayMesh)
	terrain_material.set_shader_parameter("core_pos", core_center)
	terrain_material.set_shader_parameter("pad_radius", 19.0)
	_rebuild_dressing()


## Glowing Xenite deposits on open ground (2x2 cells) for Mining Rigs.
func _place_deposits(seed_value: int, mouths: Array) -> void:
	deposit.resize(w * h)
	deposit.fill(0)
	deposit_centers.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 77
	var tries := 0
	while deposit_centers.size() < 10 and tries < 4000:
		tries += 1
		var x := rng.randi_range(8, w - 9)
		var z := rng.randi_range(8, h - 9)
		var ok := true
		for oz in range(-1, 3):
			for ox in range(-1, 3):
				if kind[idx(x + ox, z + oz)] != Kind.GROUND:
					ok = false
		for m: Vector2i in mouths:
			if Vector2(x, z).distance_to(Vector2(m)) < 18.0:
				ok = false
		for dcen in deposit_centers:
			if Vector2(x, z).distance_to(Vector2(dcen)) < 16.0:
				ok = false
		if not ok:
			continue
		deposit_centers.append(Vector2i(x, z))
		for oz in range(0, 2):
			for ox in range(0, 2):
				deposit[idx(x + ox, z + oz)] = 1


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
	for k in 60:
		var cx := rng.randf_range(origin.x + 6, origin.x + w - 6)
		var cz := rng.randf_range(origin.y + 6, origin.y + h - 6)
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
			hgrid[j * hw + i] = hgt
	hbase = hgrid.duplicate()


func _build_terrain_mesh() -> void:
	var mesh := ArrayMesh.new()
	_fill_terrain_mesh(mesh)
	_terrain = MeshInstance3D.new()
	_terrain.layers = 1 | TERRAIN_LAYER
	_terrain.name = "Terrain"
	_terrain.mesh = mesh
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = preload("res://scripts/render/terrain.gdshader")
	terrain_material.set_shader_parameter("pad_radius", 0.0)
	terrain_material.set_shader_parameter("detail", _relief)
	_terrain.material_override = terrain_material
	add_child(_terrain)


func _fill_terrain_mesh(mesh: ArrayMesh) -> void:
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
	# concavity: how far each vertex sits below the 3 m average around it
	# (creases at cliff feet, crater walls), baked into the vertex colour
	var blur := _box_blur(hgrid, hw, hh, 6)
	var cols := PackedColorArray()
	cols.resize(hw * hh)
	for k in hw * hh:
		var cav := clampf(1.0 - maxf(0.0, blur[k] - hgrid[k]) * 0.45, 0.5, 1.0)
		cols[k] = Color(cav, cav, cav)
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
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idxs
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)


## Separable box blur with running sums (O(n) per pass, any radius).
static func _box_blur(src: PackedFloat32Array, ww: int, hh_: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(src.size())
	var out := PackedFloat32Array()
	out.resize(src.size())
	var inv := 1.0 / float(2 * r + 1)
	for j in hh_:
		var row := j * ww
		var acc := 0.0
		for i in range(-r, r + 1):
			acc += src[row + clampi(i, 0, ww - 1)]
		for i in ww:
			tmp[row + i] = acc * inv
			acc += src[row + mini(i + r + 1, ww - 1)] - src[row + maxi(i - r, 0)]
	for i in ww:
		var acc := 0.0
		for j in range(-r, r + 1):
			acc += tmp[clampi(j, 0, hh_ - 1) * ww + i]
		for j in hh_:
			out[j * ww + i] = acc * inv
			acc += tmp[mini(j + r + 1, hh_ - 1) * ww + i] - tmp[maxi(j - r, 0) * ww + i]
	return out


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
			if deposit[c] or (has_base() and cell_center(c).distance_to(core_center) < 20.0):
				chance = 0.0
			if rng.randf() < chance:
				var p := cell_center(c) + Vector3(rng.randf_range(-0.4, 0.4), 0, rng.randf_range(-0.4, 0.4))
				p.y = height_at(p.x, p.z) - 0.05
				var sc := rng.randf_range(0.18, 0.55) * (1.4 if near_rock else 1.0)
				var b := Basis.from_euler(Vector3(rng.randf() * 0.6, rng.randf() * TAU, rng.randf() * 0.6)).scaled(Vector3(sc * rng.randf_range(0.8, 1.4), sc * rng.randf_range(0.5, 0.9), sc))
				boulders.append(Transform3D(b, p))
		elif kind[c] == Kind.ROCK and near_rock and not is_core(c) and rng.randf() < 0.05:
			var p := cell_center(c)
			p.y = height_at(p.x, p.z) - 0.1
			var sc := rng.randf_range(0.5, 1.1)
			crystals.append(Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3.ONE * sc), p))
	_scatter_mmi(StationModels.boulder_mesh(), boulders, StationModels.rock_material())
	_scatter_mmi(StationModels.crystal_mesh(), crystals, StationModels.crystal_material())
	_build_pebbles(rng)
	_build_debris(rng)


## Pebble fields: thousands of small stones, denser at cliff feet and in
## gravel patches, kept off the base pad. Chunked so distant chunks are culled
## (and the Low graphics preset can hide them).
var _pebble_chunks: Array[MultiMeshInstance3D] = []
var _pebbles_on := true
var _relief := 1.0
func _build_pebbles(rng: RandomNumberGenerator) -> void:
	_pebble_chunks.clear()
	var noise := FastNoiseLite.new()
	noise.seed = 77
	noise.frequency = 0.06
	const CH := 25
	var per: Dictionary = {}   # chunk key -> [xforms, colours]
	var mesh := StationModels.pebble_mesh()
	var tints := [Color(0.42, 0.26, 0.2), Color(0.55, 0.3, 0.18), Color(0.3, 0.2, 0.17), Color(0.68, 0.45, 0.3), Color(0.24, 0.16, 0.14)]
	for c in w * h:
		if kind[c] != Kind.GROUND or deposit[c]:
			continue
		var x := c % w
		var z := c / w
		if x < 1 or z < 1 or x >= w - 1 or z >= h - 1:
			continue
		var p0 := cell_center(c)
		if has_base() and p0.distance_to(core_center) < 17.0:
			continue
		var near_rock := kind[c - 1] == Kind.ROCK or kind[c + 1] == Kind.ROCK or kind[c - w] == Kind.ROCK or kind[c + w] == Kind.ROCK
		var field := noise.get_noise_2d(p0.x, p0.z)
		var n := 0
		if near_rock:
			n = rng.randi_range(1, 4)
		elif field > 0.25:
			n = rng.randi_range(1, 3)
		elif rng.randf() < 0.18:
			n = 1
		for k in n:
			var p := p0 + Vector3(rng.randf_range(-0.48, 0.48), 0, rng.randf_range(-0.48, 0.48))
			p.y = height_at(p.x, p.z) - 0.015
			var sc := rng.randf_range(0.035, 0.14) * (1.5 if near_rock else 1.0)
			var b := Basis.from_euler(Vector3(rng.randf() * 0.8, rng.randf() * TAU, rng.randf() * 0.8)).scaled(Vector3(sc * rng.randf_range(0.8, 1.5), sc * rng.randf_range(0.4, 0.8), sc))
			var key := (x / CH) * 1000 + (z / CH)
			if not per.has(key):
				per[key] = [[], []]
			per[key][0].append(Transform3D(b, p))
			per[key][1].append(tints[rng.randi() % tints.size()])
	for key: int in per:
		var xfs: Array = per[key][0]
		var cols: Array = per[key][1]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = xfs.size()
		for i in xfs.size():
			mm.set_instance_transform(i, xfs[i])
			mm.set_instance_color(i, cols[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = StationModels.rock_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = 90.0
		mmi.visibility_range_end_margin = 12.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mmi.visible = _pebbles_on
		_dressing.add_child(mmi)
		_pebble_chunks.append(mmi)


## Abandoned mining kit from an earlier survey crew, scattered in the open.
func _build_debris(rng: RandomNumberGenerator) -> void:
	var placed := 0
	var tries := 0
	while placed < 26 and tries < 4000:
		tries += 1
		var c := rng.randi() % (w * h)
		if kind[c] != Kind.GROUND or deposit[c]:
			continue
		var p := cell_center(c)
		if has_base() and p.distance_to(core_center) < 22.0:
			continue
		p.y = height_at(p.x, p.z) - 0.04
		var mi := MeshInstance3D.new()
		mi.mesh = StationModels.debris_mesh(placed)
		mi.material_override = StationModels.station_material()
		mi.position = p
		mi.rotation.y = rng.randf() * TAU
		_dressing.add_child(mi)
		placed += 1


## Graphics quality: terrain relief strength and the pebble fields.
func set_surface_detail(relief: float, pebbles: bool) -> void:
	_relief = relief
	_pebbles_on = pebbles
	if terrain_material:
		terrain_material.set_shader_parameter("detail", relief)
	for m in _pebble_chunks:
		if is_instance_valid(m):
			m.visible = pebbles


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
	_dressing.add_child(mmi)


# ---------------------------------------------------------------- visuals

func _build_visuals() -> void:
	_build_terrain_mesh()
	_build_skirt()
	_rebuild_dressing()


## Plateau ground stretching past the map edge so the world never ends in a void.
func _build_skirt() -> void:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.42, 0.2, 0.1)
	m.roughness = 0.95
	var size := 600.0
	var cx := origin.x + w * 0.5
	var cz := origin.y + h * 0.5
	var y := 3.4
	# four slabs around the map rectangle
	var rects := [
		Rect2(cx - size * 0.5, origin.y - size * 0.5, size, size * 0.5 - 0.6),
		Rect2(cx - size * 0.5, origin.y + h + 0.6, size, size * 0.5),
		Rect2(cx - size * 0.5, origin.y - 0.6, size * 0.5 - w * 0.5 - 0.6, h + 1.2),
		Rect2(origin.x + w + 0.6, origin.y - 0.6, size * 0.5 - w * 0.5, h + 1.2),
	]
	for r: Rect2 in rects:
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = r.size
		mi.mesh = pm
		mi.material_override = m
		mi.position = Vector3(r.position.x + r.size.x * 0.5, y, r.position.y + r.size.y * 0.5)
		add_child(mi)


## Scatter, Xenite deposits, props and (once landed) the hab dome. Rebuilt
## when the outpost lands so nothing clutters the base pad.
func _rebuild_dressing() -> void:
	if _dressing:
		_dressing.queue_free()
	_dressing = Node3D.new()
	_dressing.name = "Dressing"
	add_child(_dressing)
	_build_scatter(int(GameConfig.section("test_range").get("seed", 1337)))
	_build_deposits()
	if has_base():
		var core := Node3D.new()
		core.name = "HabDome"
		core.position = cell_ground(idx(base_cell.x, base_cell.y))
		_dressing.add_child(core)
		StationModels.build_command_hab(core)
		_place_props()


func _build_deposits() -> void:
	var xfs: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for dc in deposit_centers:
		for k in 5:
			var p := Vector3(origin.x + dc.x + rng.randf_range(0.2, 1.8), 0, origin.y + dc.y + rng.randf_range(0.2, 1.8))
			p.y = height_at(p.x, p.z) - 0.05
			var sc := rng.randf_range(0.35, 0.7)
			xfs.append(Transform3D(Basis.from_euler(Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3))).scaled(Vector3.ONE * sc), p))
		var glow := OmniLight3D.new()
		glow.light_color = Color(0.2, 1.0, 0.85)
		glow.omni_range = 5.0
		glow.light_energy = 1.2
		glow.position = Vector3(origin.x + dc.x + 1.0, height_at(origin.x + dc.x + 1.0, origin.y + dc.y + 1.0) + 1.2, origin.y + dc.y + 1.0)
		_dressing.add_child(glow)
	_scatter_mmi(StationModels.crystal_mesh(), xfs, StationModels.crystal_material())


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
		_dressing.add_child(prop)
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
