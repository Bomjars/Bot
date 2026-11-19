class_name Corpses
extends Node3D
## Persistent alien corpses. One ring buffer + MultiMesh per strain (same mesh
## as the living alien, rolled onto its side and darkened by the shader).
## When the cap is reached the oldest corpse of that strain decays.
##
## Corpses pile up physically: each corpse adds its corpse_height to the
## cell's pile and rests on top of what is already there. A pile next to a
## wall that reaches climb_height makes the wall climbable (see OutpostMap).
## Corpses remember whether they were charred (incendiary kill) - burned
## corpses yield no Biomass from M3 on.

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
var _mm: Array[MultiMesh] = []
var _dirty := PackedByteArray()
var _rng := RandomNumberGenerator.new()


func setup(m: OutpostMap, pools: Array[AlienPool], material: Material) -> void:
	map = m
	total_cap = int(GameConfig.section("combat").get("corpse_cap", total_cap))
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
		_remove_slot(t, i)
	var rest := map.add_pile(c, height)
	cells[i] = c
	_height[t][i] = height
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
	count -= 1
	if _charred[t][i]:
		charred_count -= 1
	var o := i * STRIDE
	var buf := _buf[t]
	for k in 12:
		buf[o + k] = 0.0
	_dirty[t] = 1


func clear() -> void:
	for t in _cap.size():
		for i in _cap[t]:
			_cell[t][i] = -1
		_buf[t].fill(0.0)
		_dirty[t] = 1
	count = 0
	charred_count = 0
	map.reset_piles()


func upload() -> void:
	for t in _mm.size():
		if _dirty[t]:
			RenderingServer.multimesh_set_buffer(_mm[t].get_rid(), _buf[t])
			_dirty[t] = 0
