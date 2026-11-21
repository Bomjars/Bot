class_name AlienPool
extends RefCounted
## Structure-of-arrays storage for one alien strain + its MultiMesh.
## Slots are dense [0, count); removal swaps the last alien in (O(1)), so an
## alien's index is only valid within a frame. Handles = (type << 17) | index.
## The render buffer is written in the same pass as the simulation.

const STRIDE := 16  # 12 floats transform + 4 floats custom (flash, dead, charred, -)

var type_id := 0
var def: Dictionary
var count := 0
var capacity := 0

# cached traits
var burrows := false
var dodge := 0.0
var ranged_range := 0.0
var ranged_cd := 0.0
var ranged_dmg := 0.0
var brood_interval := 0.0
var brood_count := 0
var brood_type := 0
var ichor := Color.WHITE
var abducts := false
var mauls := false
var hunts := false
var feed_rate := 0.0

var px := PackedFloat32Array()
var pz := PackedFloat32Array()
var vx := PackedFloat32Array()
var vz := PackedFloat32Array()
var hp := PackedFloat32Array()
var speed := PackedFloat32Array()
var size := PackedFloat32Array()   # grows when feeding (M4)
var timer := PackedFloat32Array()  # spit cooldown / brood timer / surfaced stun
var slow := PackedFloat32Array()   # seconds of shock slow left
var burn := PackedFloat32Array()   # seconds of burning left
var aux := PackedFloat32Array()    # burrowers: 1 = underground
var tgt := PackedInt32Array()      # spitters: structure cell being shelled
var carry := PackedInt32Array()    # colonist id being dragged off, -1 none
var feed := PackedFloat32Array()   # seconds left eating a corpse
var stuck := PackedFloat32Array()  # seconds not moving without a reason (diagnostics / unstick)
var bucket := PackedInt32Array()   # spatial grid bucket (written by sim)
var lnext := PackedInt32Array()    # spatial grid linked list
var buf := PackedFloat32Array()

var multimesh: MultiMesh
var instance: MultiMeshInstance3D


func _init(id: int, d: Dictionary, mesh: Mesh, material: Material) -> void:
	type_id = id
	def = d
	burrows = bool(d.get("burrows", false))
	dodge = float(d.get("dodge", 0.0))
	var r: Dictionary = d.get("ranged", {})
	ranged_range = float(r.get("range", 0.0))
	ranged_cd = float(r.get("cooldown", 2.0))
	ranged_dmg = float(r.get("damage", 0.0))
	var b: Dictionary = d.get("brood", {})
	brood_interval = float(b.get("interval", 0.0))
	brood_count = int(b.get("count", 0))
	brood_type = maxi(0, GameConfig.alien_index(b.get("type", "stalker")))
	ichor = Color(d.get("ichor", "#c8e04a"))
	abducts = bool(d.get("abducts", false))
	mauls = bool(d.get("mauls", false))
	hunts = bool(d.get("hunts", false))
	feed_rate = float(d.get("feed_rate", 0.0))

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
	for a: PackedFloat32Array in [px, pz, vx, vz, hp, speed, size, timer, slow, burn, aux, feed, stuck]:
		a.resize(capacity)
	for a: PackedInt32Array in [tgt, bucket, lnext, carry]:
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
	timer[i] = rng.randf() * maxf(brood_interval, ranged_cd)
	slow[i] = 0.0
	burn[i] = 0.0
	aux[i] = 1.0 if burrows else 0.0
	tgt[i] = -1
	carry[i] = -1
	feed[i] = 0.0
	stuck[i] = 0.0
	bucket[i] = 0
	var o := i * STRIDE
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
		timer[i] = timer[last]; slow[i] = slow[last]; burn[i] = burn[last]
		aux[i] = aux[last]; tgt[i] = tgt[last]; bucket[i] = bucket[last]
		carry[i] = carry[last]; feed[i] = feed[last]; stuck[i] = stuck[last]
		var o := i * STRIDE
		var ol := last * STRIDE
		for k in STRIDE:
			buf[o + k] = buf[ol + k]
	count = last


## Facing yaw (radians) read back from the render buffer.
func yaw(i: int) -> float:
	var o := i * STRIDE
	return atan2(buf[o + 2], buf[o + 10])


func upload() -> void:
	multimesh.visible_instance_count = count
	if count > 0:
		RenderingServer.multimesh_set_buffer(multimesh.get_rid(), buf)
