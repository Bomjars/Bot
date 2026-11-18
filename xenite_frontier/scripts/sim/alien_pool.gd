class_name AlienPool
extends RefCounted
## Structure-of-arrays storage for one alien strain + its MultiMesh.
## Slots are dense [0, count); removal swaps the last alien in (O(1)).
## The render buffer is written in the same pass as the simulation.

const STRIDE := 16  # 12 floats transform + 4 floats custom data

var type_id := 0
var def: Dictionary
var count := 0
var capacity := 0

var px := PackedFloat32Array()
var pz := PackedFloat32Array()
var vx := PackedFloat32Array()
var vz := PackedFloat32Array()
var hp := PackedFloat32Array()
var speed := PackedFloat32Array()
var size := PackedFloat32Array()   # grows when feeding (M4)
var buf := PackedFloat32Array()

var multimesh: MultiMesh
var instance: MultiMeshInstance3D


func _init(id: int, d: Dictionary, mesh: Mesh, material: Material) -> void:
	type_id = id
	def = d
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	instance = MultiMeshInstance3D.new()
	instance.name = "Pool_%s" % d.id
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# swarm covers the whole map; skip per-frame AABB recompute & culling
	instance.custom_aabb = AABB(Vector3(-1000, -10, -1000), Vector3(2000, 40, 2000))
	_grow(256)


func _grow(new_cap: int) -> void:
	capacity = new_cap
	for a: PackedFloat32Array in [px, pz, vx, vz, hp, speed, size]:
		a.resize(capacity)
	buf.resize(capacity * STRIDE)
	multimesh.instance_count = capacity
	multimesh.visible_instance_count = count


func spawn(x: float, z: float, rng: RandomNumberGenerator) -> int:
	if count >= capacity:
		_grow(int(capacity * 1.5) + 64)
	var i := count
	count += 1
	px[i] = x
	pz[i] = z
	vx[i] = 0.0
	vz[i] = 0.0
	hp[i] = float(def.hp)
	speed[i] = float(def.speed) * rng.randf_range(0.85, 1.15)
	var s := float(def.size) * rng.randf_range(0.9, 1.1)
	size[i] = s
	var o := i * STRIDE
	# basis facing +Z, scaled
	buf[o] = s; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = x
	buf[o + 4] = 0.0; buf[o + 5] = s; buf[o + 6] = 0.0; buf[o + 7] = 0.0
	buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = s; buf[o + 11] = z
	buf[o + 12] = 0.0; buf[o + 13] = 0.0; buf[o + 14] = 0.0; buf[o + 15] = 0.0
	return i


func remove(i: int) -> void:
	var last := count - 1
	if i != last:
		px[i] = px[last]; pz[i] = pz[last]
		vx[i] = vx[last]; vz[i] = vz[last]
		hp[i] = hp[last]; speed[i] = speed[last]; size[i] = size[last]
		var o := i * STRIDE
		var ol := last * STRIDE
		for k in STRIDE:
			buf[o + k] = buf[ol + k]
	count = last


func upload() -> void:
	multimesh.visible_instance_count = count
	if count > 0:
		RenderingServer.multimesh_set_buffer(multimesh.get_rid(), buf)
