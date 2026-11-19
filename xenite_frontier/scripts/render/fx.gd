class_name Fx
extends Node3D
## Pooled visual effects, all MultiMesh (one draw call each):
##  - particles: gibs, sparks, flame, smoke, acid. Ballistic motion + gravity,
##    gibs stick to the ground. Ring buffer: oldest is recycled.
##  - beams: tracers, rail slugs, shock arcs. Stretched boxes that thin out.
##  - splats: persistent ichor puddles on the ground (ring buffer).
## Instance colour alpha = glow strength.

const STRIDE := 16

var p_cap := 4000
var b_cap := 384
var s_cap := 2500

# particles
var _ppx := PackedFloat32Array(); var _ppy := PackedFloat32Array(); var _ppz := PackedFloat32Array()
var _pvx := PackedFloat32Array(); var _pvy := PackedFloat32Array(); var _pvz := PackedFloat32Array()
var _plife := PackedFloat32Array(); var _pmax := PackedFloat32Array()
var _psize := PackedFloat32Array(); var _pgrav := PackedFloat32Array()
var _pbuf := PackedFloat32Array()
var _p_next := 0
var _p_active := 0
var _p_mm: MultiMesh

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

var gore := true
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
	_p_mm = _make_mm(pbox, p_cap, mat)
	for a in [_ppx, _ppy, _ppz, _pvx, _pvy, _pvz, _plife, _pmax, _psize, _pgrav]:
		a.resize(p_cap)
		a.fill(0.0)
	_pbuf.resize(p_cap * STRIDE)
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


func _make_mm(mesh: Mesh, n: int, mat: Material) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
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
	_plife.fill(0.0)
	_pbuf.fill(0.0)
	_blife.fill(0.0)
	_bbuf.fill(0.0)
	_sbuf.fill(0.0)
	_s_dirty = true
	_p_active = 1


# ---------------------------------------------------------------- spawning

func particle(pos: Vector3, vel: Vector3, col: Color, size: float, life: float, grav := 1.0) -> void:
	var i := _p_next
	_p_next = (_p_next + 1) % p_cap
	_ppx[i] = pos.x; _ppy[i] = pos.y; _ppz[i] = pos.z
	_pvx[i] = vel.x; _pvy[i] = vel.y; _pvz[i] = vel.z
	_plife[i] = life; _pmax[i] = life
	_psize[i] = size; _pgrav[i] = grav
	var o := i * STRIDE
	_pbuf[o + 12] = col.r; _pbuf[o + 13] = col.g; _pbuf[o + 14] = col.b; _pbuf[o + 15] = col.a
	_p_active += 1


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


func splat(pos: Vector3, col: Color, radius: float) -> void:
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
	_sbuf[o + 4] = 0.0; _sbuf[o + 5] = 1.0; _sbuf[o + 6] = 0.0; _sbuf[o + 7] = pos.y + 0.012 + rng.randf() * 0.01
	_sbuf[o + 8] = -s * sx; _sbuf[o + 9] = 0.0; _sbuf[o + 10] = c * sz; _sbuf[o + 11] = pos.z
	var dcol := col.darkened(0.35)
	_sbuf[o + 12] = dcol.r; _sbuf[o + 13] = dcol.g; _sbuf[o + 14] = dcol.b; _sbuf[o + 15] = 0.15
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
	splat(pos, ichor, 0.5 + 0.25 * scale)


# ---------------------------------------------------------------- update

func update(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	if _p_active > 0:
		_update_particles(dt)
	_update_beams(dt)
	if _s_dirty:
		RenderingServer.multimesh_set_buffer(_s_mm.get_rid(), _sbuf)
		_s_dirty = false
	update_usec = Time.get_ticks_usec() - t0


func _update_particles(dt: float) -> void:
	var active := 0
	var buf := _pbuf
	var g := 14.0 * dt
	for i in p_cap:
		var l := _plife[i]
		if l <= 0.0:
			continue
		l -= dt
		var o := i * STRIDE
		if l <= 0.0:
			_plife[i] = 0.0
			buf[o] = 0.0; buf[o + 5] = 0.0; buf[o + 10] = 0.0
			continue
		_plife[i] = l
		active += 1
		var vy := _pvy[i] - g * _pgrav[i]
		var y := _ppy[i] + vy * dt
		var x := _ppx[i]
		var z := _ppz[i]
		if y < 0.04 and _pgrav[i] > 0.0:
			y = 0.04
			vy = 0.0
			_pvx[i] *= 0.5
			_pvz[i] *= 0.5
		x += _pvx[i] * dt
		z += _pvz[i] * dt
		_ppx[i] = x; _ppy[i] = y; _ppz[i] = z
		_pvy[i] = vy
		var s := _psize[i] * minf(1.0, l / _pmax[i] * 3.0)
		buf[o] = s; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = x
		buf[o + 4] = 0.0; buf[o + 5] = s; buf[o + 6] = 0.0; buf[o + 7] = y
		buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = s; buf[o + 11] = z
	_p_active = active
	RenderingServer.multimesh_set_buffer(_p_mm.get_rid(), buf)


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
