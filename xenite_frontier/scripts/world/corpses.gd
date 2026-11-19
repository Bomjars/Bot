class_name Corpses
extends Node3D
## Persistent alien corpses. One ring buffer + MultiMesh per strain (same mesh
## as the living alien, rolled onto its side and darkened by the shader).
## When the cap is reached the oldest corpse of that strain decays.
##
## Corpses pile up physically: each corpse adds its corpse_height to the
## cell's pile and rests on top of what is already there. A pile next to a
## wall that reaches climb_height makes the wall climbable (see OutpostMap).
## Corpses hold Biomass (economy.json per strain). Charred corpses
## (incendiary kills) hold none. Harvester drones claim a corpse, then
## harvest it: the corpse is removed, which also lowers its pile. Each slot
## carries a serial so a drone can tell if its target decayed and was reused.

const STRIDE := 16

var map: OutpostMap
var total_cap := 4000
var count := 0          # live corpses
var charred_count := 0

var _cap := PackedInt32Array()
var _next := PackedInt32Array()
var _cell: Array[PackedInt32Array] = []
var _height: Array[PackedFloat32Array] = []
var _charred: Array[PackedByteArray] = []
var _buf: Array[PackedFloat32Array] = []
var _x: Array[PackedFloat32Array] = []
var _z: Array[PackedFloat32Array] = []
var _value: Array[PackedFloat32Array] = []
var _claimed: Array[PackedByteArray] = []
var _serial: Array[PackedInt32Array] = []
var _biomass_of := PackedFloat32Array()
var _charred_yield := 0.0
var _next_serial := 1
var biomass_lost := 0.0     # value that decayed before harvest
var harvested := 0
var _mm: Array[MultiMesh] = []
var _dirty := PackedByteArray()
var _rng := RandomNumberGenerator.new()


func setup(m: OutpostMap, pools: Array[AlienPool], material: Material) -> void:
	map = m
	total_cap = int(GameConfig.section("combat").get("corpse_cap", total_cap))
	_charred_yield = float(GameConfig.econ("biomass").get("charred_yield", 0.0))
	var wsum := 0.0
	for p in pools:
		wsum += float(p.def.get("spawn_weight", 1))
	for p in pools:
		var share := float(p.def.get("spawn_weight", 1)) / wsum
		# small strains still get a useful buffer (bosses leave big corpses)
		var c := maxi(48, int(total_cap * share))
		_cap.append(c)
		_next.append(0)
		var cell := PackedInt32Array(); cell.resize(c); cell.fill(-1)
		var hh := PackedFloat32Array(); hh.resize(c); hh.fill(0.0)
		var ch := PackedByteArray(); ch.resize(c); ch.fill(0)
		var b := PackedFloat32Array(); b.resize(c * STRIDE); b.fill(0.0)
		_cell.append(cell); _height.append(hh); _charred.append(ch); _buf.append(b)
		for arr in [_x, _z, _value]:
			var f := PackedFloat32Array(); f.resize(c); f.fill(0.0)
			arr.append(f)
		var cl := PackedByteArray(); cl.resize(c); cl.fill(0)
		_claimed.append(cl)
		var se := PackedInt32Array(); se.resize(c); se.fill(0)
		_serial.append(se)
		_biomass_of.append(GameConfig.corpse_biomass(p.def.id))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = p.multimesh.mesh
		mm.instance_count = c
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Corpses_%s" % p.def.id
		mmi.multimesh = mm
		mmi.material_override = material
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = AABB(Vector3(-1000, -10, -1000), Vector3(2000, 40, 2000))
		add_child(mmi)
		_mm.append(mm)
		_dirty.append(1)


func add(t: int, x: float, z: float, yaw: float, size: float, height: float, charred: bool) -> void:
	var c := map.cell_of(Vector3(x, 0, z))
	if c < 0:
		return
	var i := _next[t]
	_next[t] = (i + 1) % _cap[t]
	var cells := _cell[t]
	if cells[i] >= 0:
		biomass_lost += _value[t][i]
		_remove_slot(t, i)
	var rest := map.add_pile(c, height)
	cells[i] = c
	_height[t][i] = height
	_x[t][i] = x
	_z[t][i] = z
	_value[t][i] = _biomass_of[t] * (_charred_yield if charred else 1.0)
	_claimed[t][i] = 0
	_serial[t][i] = _next_serial
	_next_serial += 1
	_charred[t][i] = 1 if charred else 0
	count += 1
	if charred:
		charred_count += 1
	# rolled onto its side (random side), random yaw, resting on the pile
	var roll := (PI * 0.5) * (1.0 if _rng.randf() < 0.5 else -1.0) * _rng.randf_range(0.6, 1.0)
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3.FORWARD, roll)
	b = b.scaled(Vector3(size, size, size))
	var o := i * STRIDE
	var buf := _buf[t]
	buf[o] = b.x.x; buf[o + 1] = b.y.x; buf[o + 2] = b.z.x; buf[o + 3] = x
	buf[o + 4] = b.x.y; buf[o + 5] = b.y.y; buf[o + 6] = b.z.y; buf[o + 7] = rest * 0.85 + 0.15 * size
	buf[o + 8] = b.x.z; buf[o + 9] = b.y.z; buf[o + 10] = b.z.z; buf[o + 11] = z
	buf[o + 12] = 0.0; buf[o + 13] = 1.0; buf[o + 14] = 1.0 if charred else 0.0; buf[o + 15] = 0.0
	_dirty[t] = 1


func _remove_slot(t: int, i: int) -> void:
	var c := _cell[t][i]
	if c < 0:
		return
	map.remove_pile(c, _height[t][i])
	_cell[t][i] = -1
	_claimed[t][i] = 0
	count -= 1
	if _charred[t][i]:
		charred_count -= 1
	var o := i * STRIDE
	var buf := _buf[t]
	for k in 12:
		buf[o + k] = 0.0
	_dirty[t] = 1


# ------------------------------------------------------------ harvesting

## Nearest unclaimed corpse with Biomass within `radius` of `center`, closest
## to `from`. Returns [type, slot, serial] or [] if none.
func find_harvestable(center: Vector3, radius: float, from: Vector3) -> Array:
	var r2 := radius * radius
	var best: Array = []
	var best_d := INF
	for t in _cap.size():
		var cells := _cell[t]
		var xs := _x[t]
		var zs := _z[t]
		var vals := _value[t]
		var cl := _claimed[t]
		for i in _cap[t]:
			if cells[i] < 0 or vals[i] <= 0.0 or cl[i]:
				continue
			var dx := xs[i] - center.x
			var dz := zs[i] - center.z
			if dx * dx + dz * dz > r2:
				continue
			var fx := xs[i] - from.x
			var fz := zs[i] - from.z
			var d := fx * fx + fz * fz
			if d < best_d:
				best_d = d
				best = [t, i, _serial[t][i]]
	return best


func is_valid(ref: Array) -> bool:
	return not ref.is_empty() and _cell[ref[0]][ref[1]] >= 0 and _serial[ref[0]][ref[1]] == ref[2]


func claim(ref: Array, on: bool) -> void:
	if is_valid(ref):
		_claimed[ref[0]][ref[1]] = 1 if on else 0


func position_of(ref: Array) -> Vector3:
	var t: int = ref[0]
	var i: int = ref[1]
	return Vector3(_x[t][i], _buf[t][i * STRIDE + 7], _z[t][i])


## Removes the corpse and returns its Biomass (0 if it already decayed).
func harvest(ref: Array) -> float:
	if not is_valid(ref):
		return 0.0
	var v := _value[ref[0]][ref[1]]
	_remove_slot(ref[0], ref[1])
	harvested += 1
	return v


## Removes a corpse without yield (eaten by aliens, M4 / cremated, M6).
func destroy(ref: Array) -> void:
	if is_valid(ref):
		_remove_slot(ref[0], ref[1])


func harvestable_value() -> float:
	var s := 0.0
	for t in _cap.size():
		for i in _cap[t]:
			if _cell[t][i] >= 0:
				s += _value[t][i]
	return s


func clear() -> void:
	for t in _cap.size():
		for i in _cap[t]:
			_cell[t][i] = -1
			_claimed[t][i] = 0
		_buf[t].fill(0.0)
		_dirty[t] = 1
	count = 0
	charred_count = 0
	biomass_lost = 0.0
	harvested = 0
	map.reset_piles()


func upload() -> void:
	for t in _mm.size():
		if _dirty[t]:
			RenderingServer.multimesh_set_buffer(_mm[t].get_rid(), _buf[t])
			_dirty[t] = 0
