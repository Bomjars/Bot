class_name AlienPool
extends RefCounted
## Structure-of-arrays storage for one alien strain + its MultiMesh.
## Slots are dense [0, count); removal swaps the last alien in (O(1)), so an
## alien's index is only valid within a frame. Handles = (type << 17) | index.
## The render buffer is written in the same pass as the simulation.

const STRIDE := 16  # 12 floats transform + 4 custom: flash, dead (1) / charred (2) or -(extra + 2 x enraged), stride phase, state

## Behaviour states (concept sheet "Humanoid Lineup v4 - movement notes").
enum Mode { NONE, TELL, CHARGE, STUN, RETREAT, SURFACED, FREEZE, POUNCE }

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
# v4 behaviour traits (0 = the strain doesn't do it)
var tell_time := 0.0        # Spitter sac / Burrower crack / Mauler wind-up / Elder roar
var shots := 0              # Spitter: shots per full sac
var refill := 0.0
var back_off := 0.0
var surface_time := 0.0     # Burrower: seconds above ground before sinking again
var tunnel_min := 0.0
var seismic_stun := 0.0
var tell_speed := 1.0
var charge_range := 0
var charge_min := 0
var charge_mult := 1.0
var charge_max := 0.0
var charge_impact := 0.0
var charge_door_mult := 1.0
var charge_door_stun := 0.0
var charge_stun := 0.0
var charge_cd := 0.0
var roar_interval := 0.0
var roar_radius := 0.0
var roar_duration := 0.0
var drag_mult := 0.0
var zigzag := 0.0
var ignores_turrets := false
var burst_run := 0.0        # Runt: run / freeze / pounce
var burst_freeze := 0.0
var pounce_range := 0.0
var pounce_mult := 1.0
var climb_mult := 0.0
var heavy_steps := 0.0
var feed_every := false
var feed_cooldown := 0.0
var young_start := 0
var young_max := 0
var young_per_meal := 0
var sweep := 0

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
var lane := PackedFloat32Array()   # persistent sideways offset in the flow (-1..1): packs keep a lane
var gait := PackedFloat32Array()   # stride phase, advanced by distance actually travelled
var mode := PackedInt32Array()     # Mode
var mt := PackedFloat32Array()     # seconds left in the current mode
var val := PackedFloat32Array()    # Spitter shots left / Brood Mother young clinging
var hdx := PackedFloat32Array()    # locked heading (Mauler charge)
var hdz := PackedFloat32Array()
var rage := PackedFloat32Array()   # seconds enraged by an Elder's roar
var alert := PackedFloat32Array()  # seconds since last hit (Snatchers zig-zag)
var cool := PackedFloat32Array()   # charge / roar / feed / re-breach cooldown
var bucket := PackedInt32Array()   # spatial grid bucket (written by sim)
var lnext := PackedInt32Array()    # spatial grid linked list
var buf := PackedFloat32Array()

var multimesh: MultiMesh
var instance: MultiMeshInstance3D
var mesh_near: Mesh
var mesh_far: Mesh
var stride := 1.0     # stride phase per metre walked


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
	tell_time = float(r.get("tell", 0.0))
	shots = int(r.get("shots", 0))
	refill = float(r.get("refill", 0.0))
	back_off = float(r.get("back_off", 0.0))
	var bw: Dictionary = d.get("burrow", {})
	if burrows:
		tell_time = float(bw.get("tell", 2.0))
		surface_time = float(bw.get("surface_time", 3.0))
		tunnel_min = float(bw.get("tunnel_min", 2.5))
		seismic_stun = float(bw.get("seismic_stun", 2.5))
		tell_speed = float(bw.get("tell_speed_mult", 0.2))
	var ch: Dictionary = d.get("charge", {})
	if not ch.is_empty():
		charge_range = int(ch.get("range", 12))
		charge_min = int(ch.get("min_range", 3))
		charge_mult = float(ch.get("speed_mult", 2.8))
		charge_max = float(ch.get("max_time", 3.0))
		charge_impact = float(ch.get("impact_damage", 260))
		charge_door_mult = float(ch.get("door_impact_mult", 0.4))
		charge_door_stun = float(ch.get("door_stun", 3.5))
		charge_stun = float(ch.get("stun", 1.2))
		charge_cd = float(ch.get("cooldown", 7.0))
		tell_time = float(ch.get("windup", 0.7))
	var ro: Dictionary = d.get("roar", {})
	if not ro.is_empty():
		roar_interval = float(ro.get("interval", 10.0))
		roar_radius = float(ro.get("radius", 11.0))
		roar_duration = float(ro.get("duration", 7.0))
		tell_time = float(ro.get("tell", 1.4))
	drag_mult = float(d.get("drag_speed_mult", 0.0))
	zigzag = float(d.get("zigzag", 0.0))
	ignores_turrets = bool(d.get("ignores_turrets", false))
	var bu: Dictionary = d.get("bursts", {})
	if not bu.is_empty():
		burst_run = float(bu.get("run", 0.75))
		burst_freeze = float(bu.get("freeze", 0.35))
		pounce_range = float(bu.get("pounce_range", 3.0))
		pounce_mult = float(bu.get("pounce_mult", 1.9))
	climb_mult = float(d.get("climb_mult", 0.0))
	heavy_steps = float(d.get("heavy_steps", 0.0))
	feed_every = bool(d.get("feed_every_corpse", false))
	feed_cooldown = float(d.get("feed_cooldown", 0.0))
	young_start = int(b.get("young_start", 0))
	young_max = int(b.get("young_max", 0))
	young_per_meal = int(b.get("young_per_meal", 0))
	sweep = int(d.get("sweep", {}).get("width", 0))

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
	for a: PackedFloat32Array in [px, pz, vx, vz, hp, speed, size, timer, slow, burn, aux, feed, stuck, lane, gait, mt, val, hdx, hdz, rage, alert, cool]:
		a.resize(capacity)
	for a: PackedInt32Array in [tgt, bucket, lnext, carry, mode]:
		a.resize(capacity)
	buf.resize(capacity * STRIDE)
	multimesh.instance_count = capacity
	multimesh.visible_instance_count = count


func spawn(x: float, z: float, rng: RandomNumberGenerator, hp_mult := 1.0, lane_v := 9.0) -> int:
	if count >= capacity:
		_grow(int(capacity * 1.5) + 64)
	var i := count
	count += 1
	px[i] = x
	pz[i] = z
	vx[i] = 0.0
	vz[i] = 0.0
	hp[i] = float(def.hp) * hp_mult
	speed[i] = float(def.speed) * rng.randf_range(0.78, 1.22)
	var s := float(def.size) * rng.randf_range(0.88, 1.12)
	size[i] = s
	timer[i] = rng.randf() * maxf(brood_interval, ranged_cd)
	slow[i] = 0.0
	burn[i] = 0.0
	aux[i] = 1.0 if burrows else 0.0
	tgt[i] = -1
	carry[i] = -1
	feed[i] = 0.0
	stuck[i] = 0.0
	lane[i] = lane_v if lane_v <= 1.0 else rng.randf_range(-1.0, 1.0)
	gait[i] = rng.randf() * TAU
	bucket[i] = 0
	mode[i] = Mode.NONE
	mt[i] = burst_run * rng.randf_range(0.5, 1.3)
	val[i] = float(shots) if shots > 0 else float(young_start)
	hdx[i] = 0.0
	hdz[i] = 0.0
	rage[i] = 0.0
	alert[i] = 0.0
	cool[i] = rng.randf() * maxf(roar_interval * 0.6, 2.0) if (roar_interval > 0.0 or charge_range > 0) else 0.0
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
		lane[i] = lane[last]; gait[i] = gait[last]
		mode[i] = mode[last]; mt[i] = mt[last]; val[i] = val[last]
		hdx[i] = hdx[last]; hdz[i] = hdz[last]; rage[i] = rage[last]
		alert[i] = alert[last]; cool[i] = cool[last]
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
