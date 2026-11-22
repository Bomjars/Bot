class_name Fx
extends Node3D
## Pooled visual effects, all MultiMesh (one draw call each):
##  - particles: gibs, sparks, flame, smoke, acid. Ballistic motion + gravity,
##    gibs stick to the ground. Ring buffer: oldest is recycled. Simulated on
##    the GPU (fx_particle.gdshader): the CPU only writes a slot when one
##    spawns, so thousands cost the same as a few.
##  - beams: tracers, rail slugs, shock arcs. Stretched boxes that thin out.
##  - splats: persistent ichor puddles on the ground (ring buffer).
## Instance colour alpha = glow strength.

const STRIDE := 16

var p_cap := 4000
var b_cap := 384
var s_cap := 2500

# particles (GPU-simulated): 12 transform + 4 colour + 4 custom floats each
const P_STRIDE := 20
var _pbuf := PackedFloat32Array()
var _p_next := 0
var _p_dirty := false
var _p_mm: MultiMesh
var _p_mat: ShaderMaterial
var _time := 0.0

# beams
var _bfrom: Array[Vector3] = []
var _bto: Array[Vector3] = []
var _bw := PackedFloat32Array()
var _blife := PackedFloat32Array()
var _bmax := PackedFloat32Array()
var _bbuf := PackedFloat32Array()
var _b_next := 0
var _b_mm: MultiMesh

# splats
var _sbuf := PackedFloat32Array()
var _s_next := 0
var _s_dirty := false
var _s_mm: MultiMesh

var _texts: Array[Label3D] = []
var _text_life := PackedFloat32Array()
var _text_next := 0

var gore := true
var map: OutpostMap   # terrain height for gibs and splats
var rng := RandomNumberGenerator.new()
var update_usec := 0


func setup() -> void:
	var cc := GameConfig.section("combat")
	p_cap = int(cc.get("particle_cap", p_cap))
	s_cap = int(cc.get("splat_cap", s_cap))
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://scripts/render/fx.gdshader")

	var pbox := BoxMesh.new()
	pbox.size = Vector3.ONE
	_p_mat = ShaderMaterial.new()
	_p_mat.shader = preload("res://scripts/render/fx_particle.gdshader")
	_p_mm = _make_mm(pbox, p_cap, _p_mat, true)
	_pbuf.resize(p_cap * P_STRIDE)
	_pbuf.fill(0.0)

	var bbox := BoxMesh.new()
	bbox.size = Vector3.ONE
	_b_mm = _make_mm(bbox, b_cap, mat)
	_bfrom.resize(b_cap); _bto.resize(b_cap)
	for a in [_bw, _blife, _bmax]:
		a.resize(b_cap)
		a.fill(0.0)
	_bbuf.resize(b_cap * STRIDE)
	_bbuf.fill(0.0)

	var disc := CylinderMesh.new()
	disc.top_radius = 1.0; disc.bottom_radius = 1.0; disc.height = 0.02
	disc.radial_segments = 9; disc.rings = 0
	_s_mm = _make_mm(disc, s_cap, mat)
	_sbuf.resize(s_cap * STRIDE)
	_sbuf.fill(0.0)

	for k in 24:
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.fixed_size = true
		l.pixel_size = 0.0015
		l.font_size = 30
		l.outline_size = 10
		l.visible = false
		add_child(l)
		_texts.append(l)
	_text_life.resize(24)
	_text_life.fill(0.0)
	# upload the zeroed buffers now: GPU multimesh storage starts out
	# uninitialised, and until the first effect spawns it would draw garbage
	RenderingServer.multimesh_set_buffer(_p_mm.get_rid(), _pbuf)
	RenderingServer.multimesh_set_buffer(_b_mm.get_rid(), _bbuf)
	RenderingServer.multimesh_set_buffer(_s_mm.get_rid(), _sbuf)


func _make_mm(mesh: Mesh, n: int, mat: Material, custom := false) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = custom
	mm.mesh = mesh
	mm.instance_count = n
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-1000, -10, -1000), Vector3(2000, 60, 2000))
	add_child(mmi)
	return mm


func clear() -> void:
	_pbuf.fill(0.0)
	_p_dirty = true
	_blife.fill(0.0)
	_bbuf.fill(0.0)
	_sbuf.fill(0.0)
	_s_dirty = true


# ---------------------------------------------------------------- spawning

func particle(pos: Vector3, vel: Vector3, col: Color, size: float, life: float, grav := 1.0) -> void:
	var i := _p_next
	_p_next = (_p_next + 1) % p_cap
	var o := i * P_STRIDE
	var ground := pos.y - 100.0
	if map and grav > 0.0:
		ground = map.height_at(pos.x, pos.z) + 0.04
	var b := _pbuf
	# basis X = velocity, basis Y = (ground, gravity, 0), origin = spawn point
	b[o] = vel.x; b[o + 1] = ground; b[o + 2] = 0.0; b[o + 3] = pos.x
	b[o + 4] = vel.y; b[o + 5] = grav; b[o + 6] = 0.0; b[o + 7] = maxf(pos.y, ground)
	b[o + 8] = vel.z; b[o + 9] = 0.0; b[o + 10] = 0.0; b[o + 11] = pos.z
	b[o + 12] = col.r; b[o + 13] = col.g; b[o + 14] = col.b; b[o + 15] = col.a
	b[o + 16] = _time; b[o + 17] = life; b[o + 18] = size; b[o + 19] = 0.0
	_p_dirty = true


func burst(pos: Vector3, col: Color, n: int, speed: float, size: float, life: float, grav := 1.0, up := 0.6) -> void:
	for k in n:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.2, 1.0) * up * 2.0, rng.randf_range(-1, 1)).normalized()
		particle(pos, d * speed * rng.randf_range(0.4, 1.0), col, size * rng.randf_range(0.6, 1.3), life * rng.randf_range(0.6, 1.2), grav)


func beam(from: Vector3, to: Vector3, col: Color, width: float, life: float) -> void:
	var i := _b_next
	_b_next = (_b_next + 1) % b_cap
	_bfrom[i] = from
	_bto[i] = to
	_bw[i] = width
	_blife[i] = life
	_bmax[i] = life
	var o := i * STRIDE
	_bbuf[o + 12] = col.r; _bbuf[o + 13] = col.g; _bbuf[o + 14] = col.b; _bbuf[o + 15] = col.a


## Jagged electric arc made of several short beams.
func arc(from: Vector3, to: Vector3, col: Color) -> void:
	var segs := 4
	var prev := from
	for k in range(1, segs + 1):
		var p := from.lerp(to, float(k) / segs)
		if k < segs:
			p += Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.2, 0.4), rng.randf_range(-0.4, 0.4))
		beam(prev, p, col, 0.07, 0.12)
		prev = p


func splat(pos: Vector3, col: Color, radius: float, glow := 0.0) -> void:
	if not gore:
		return
	var i := _s_next
	_s_next = (_s_next + 1) % s_cap
	var o := i * STRIDE
	var a := rng.randf() * TAU
	var sx := radius * rng.randf_range(0.8, 1.3)
	var sz := radius * rng.randf_range(0.6, 1.0)
	var c := cos(a)
	var s := sin(a)
	_sbuf[o] = c * sx; _sbuf[o + 1] = 0.0; _sbuf[o + 2] = s * sz; _sbuf[o + 3] = pos.x
	var gy := map.height_at(pos.x, pos.z) if map else pos.y
	_sbuf[o + 4] = 0.0; _sbuf[o + 5] = 1.0; _sbuf[o + 6] = 0.0; _sbuf[o + 7] = gy + 0.03 + rng.randf() * 0.02
	_sbuf[o + 8] = -s * sx; _sbuf[o + 9] = 0.0; _sbuf[o + 10] = c * sz; _sbuf[o + 11] = pos.z
	# dark, saturated acid stain (no glow) so puddles read as ground decals
	var dcol := Color.from_hsv(col.h, minf(1.0, col.s * 1.2), col.v * (0.38 + glow * 0.4))
	_sbuf[o + 12] = dcol.r; _sbuf[o + 13] = dcol.g; _sbuf[o + 14] = dcol.b; _sbuf[o + 15] = glow
	_s_dirty = true


## Alien death: chunks of carapace flying apart plus acidic ichor spray.
func gib(pos: Vector3, body: Color, ichor: Color, scale: float) -> void:
	if not gore:
		burst(pos + Vector3(0, 0.4, 0), Color(0.3, 0.3, 0.3, 0.0), 3, 2.0, 0.15, 0.4, 0.0)
		return
	var n := int(clampf(4.0 * scale, 3, 16))
	burst(pos + Vector3(0, 0.5 * scale, 0), body, n, 5.0, 0.16 * scale, 2.5, 1.0)
	var ich := Color(ichor.r, ichor.g, ichor.b, 0.6)
	burst(pos + Vector3(0, 0.4 * scale, 0), ich, n + 2, 4.0, 0.09 * scale, 0.9, 1.0)
	splat(pos, ichor, 0.3 + 0.15 * scale)


## Rising, fading text (Biomass deposits, warnings).
func float_text(pos: Vector3, text: String, col: Color) -> void:
	var k := _text_next
	_text_next = (_text_next + 1) % _texts.size()
	var l := _texts[k]
	l.text = text
	l.modulate = col
	l.position = pos
	l.visible = true
	_text_life[k] = 1.4


# ---------------------------------------------------------------- update

func update(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	_time += dt
	_p_mat.set_shader_parameter("now", _time)
	if _p_dirty:
		RenderingServer.multimesh_set_buffer(_p_mm.get_rid(), _pbuf)
		_p_dirty = false
	_update_beams(dt)
	if _s_dirty:
		RenderingServer.multimesh_set_buffer(_s_mm.get_rid(), _sbuf)
		_s_dirty = false
	for k in _texts.size():
		if _text_life[k] > 0.0:
			_text_life[k] -= dt
			var l := _texts[k]
			l.position.y += dt * 1.5
			l.modulate.a = clampf(_text_life[k], 0.0, 1.0)
			if _text_life[k] <= 0.0:
				l.visible = false
	update_usec = Time.get_ticks_usec() - t0


func _update_beams(dt: float) -> void:
	var buf := _bbuf
	var any := false
	for i in b_cap:
		var l := _blife[i]
		if l <= 0.0:
			continue
		any = true
		l -= dt
		var o := i * STRIDE
		if l <= 0.0:
			_blife[i] = 0.0
			for k in 12:
				buf[o + k] = 0.0
			continue
		_blife[i] = l
		var a := _bfrom[i]
		var b := _bto[i]
		var d := b - a
		var length := d.length()
		if length < 0.001:
			continue
		var zax := d / length
		var up := Vector3.UP if absf(zax.y) < 0.95 else Vector3.RIGHT
		var xax := up.cross(zax).normalized()
		var yax := zax.cross(xax)
		var wdt := _bw[i] * (l / _bmax[i])
		var m := (a + b) * 0.5
		xax *= wdt; yax *= wdt; zax *= length
		buf[o] = xax.x; buf[o + 1] = yax.x; buf[o + 2] = zax.x; buf[o + 3] = m.x
		buf[o + 4] = xax.y; buf[o + 5] = yax.y; buf[o + 6] = zax.y; buf[o + 7] = m.y
		buf[o + 8] = xax.z; buf[o + 9] = yax.z; buf[o + 10] = zax.z; buf[o + 11] = m.z
	if any:
		RenderingServer.multimesh_set_buffer(_b_mm.get_rid(), buf)
