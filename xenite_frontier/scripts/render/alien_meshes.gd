class_name AlienMeshes
extends RefCounted
## The swarm (art direction): grim low-poly predators of dark oily chitin and
## flesh (near-black, purple-brown) so each strain's identity colour pops:
##   Stalker   small, low, 6 thin legs, long jaw, hunched starving dog | bone-white eyes
##   Mauler    huge, front-heavy, plated shoulder shell, two club forelimbs,
##             short hind legs | deep red markings on the plates
##   Spitter   tall, thin, upright on 4 stilt legs, swollen throat sac | acid green sac
##   Snatcher  lean crouched sprinter, long hooked arms, back spines
##             | yellow eyes + yellow stripe down the spine
##   Burrower  segmented worm, drill-tooth maw, no eyes | amber glow between segments
##   Brood Mother  4x Stalker scale, bloated egg-sac abdomen, crown of horns | magenta
## Vertices carry part type / phase / joint pivot for the GPU rig in
## alien.gdshader. Each mesh is built twice: lod 0 (near) and lod 1 (far).

const GLOW := 0.0  # vertex alpha: 0 = fully emissive, 1 = none

const CHITIN := Color(0.11, 0.08, 0.1)
const FLESH := Color(0.21, 0.12, 0.13)
const DARK := Color(0.05, 0.04, 0.05)
const BONE := Color(0.72, 0.68, 0.6)

enum P { BODY, HEAD, LEG, ARM, SEG, SAC, TAIL, STATIC, SHELL }


## Shader uniforms + stride rate per strain.
static func rig(id: String) -> Dictionary:
	match id:
		"stalker":
			return {"leg_amp": 0.55, "arm_amp": 0.0, "wave_amp": 0.0, "leg_lift": 0.07, "dead_curl": 1.25, "dead_arm": 0.0, "seg_gap": 0.0, "split": 0.05, "split_y": 0.47, "sheen": 0.55, "gait_freq": 13.0}
		"mauler":
			return {"leg_amp": 0.35, "arm_amp": 0.55, "wave_amp": 0.0, "leg_lift": 0.1, "dead_curl": 0.4, "dead_arm": 0.7, "seg_gap": 0.0, "split": 0.0, "split_y": 10.0, "sheen": 0.5, "gait_freq": 5.5}
		"spitter":
			return {"leg_amp": 0.4, "arm_amp": 0.0, "wave_amp": 0.0, "leg_lift": 0.12, "dead_curl": 0.8, "dead_arm": 0.0, "seg_gap": 0.0, "split": 0.0, "split_y": 10.0, "sheen": 0.5, "gait_freq": 7.0}
		"snatcher":
			return {"leg_amp": 0.7, "arm_amp": 0.6, "wave_amp": 0.0, "leg_lift": 0.08, "dead_curl": 0.5, "dead_arm": 0.0, "seg_gap": 0.0, "split": 0.0, "split_y": 10.0, "sheen": 0.55, "gait_freq": 9.5}
		"burrower":
			return {"leg_amp": 0.0, "arm_amp": 0.0, "wave_amp": 0.14, "leg_lift": 0.0, "dead_curl": 0.0, "dead_arm": 0.0, "seg_gap": 0.3, "split": 0.0, "split_y": 10.0, "sheen": 0.6, "gait_freq": 8.0}
		"brood_mother":
			return {"leg_amp": 0.35, "arm_amp": 0.0, "wave_amp": 0.0, "leg_lift": 0.15, "dead_curl": 1.0, "dead_arm": 0.0, "seg_gap": 0.0, "split": 0.12, "split_y": 1.3, "sheen": 0.55, "gait_freq": 3.5}
	return rig("stalker")


## How the corpse lies: "side", "back", "face" (face-first) or "flat".
static func corpse_pose(id: String) -> String:
	match id:
		"snatcher": return "back"
		"mauler": return "face"
		"burrower": return "flat"
	return "side"


static func build(id: String, lod := 0) -> ArrayMesh:
	var a := MeshAcc.new()
	var hi := lod == 0
	match id:
		"stalker": _stalker(a, hi, 1.0, Color(0.95, 0.93, 0.85, GLOW))
		"mauler": _mauler(a, hi)
		"spitter": _spitter(a, hi)
		"snatcher": _snatcher(a, hi)
		"burrower": _burrower(a, hi)
		"brood_mother": _mother(a, hi)
		_: _stalker(a, hi, 1.0, Color(0.95, 0.93, 0.85, GLOW))
	return a.commit(false)


# ------------------------------------------------------------ helpers

static func _seg(hi: bool) -> int:
	return 7 if hi else 4


static func _ring(hi: bool) -> int:
	return 4 if hi else 2


## Two-segment limb hip -> knee -> foot. All vertices rotate about the hip.
static func _limb(a: MeshAcc, hip: Vector3, knee: Vector3, foot: Vector3, t1: float, t2: float, col: Color, part: int, off: float, hi: bool) -> void:
	var pv := Vector2(hip.y, hip.z)
	var cs := 5 if hi else 4
	a.add(MeshAcc.cyl(t1, 1.0, t1 * 0.8, cs), MeshAcc.limb(hip, knee), col, part, off, pv)
	a.add(MeshAcc.cyl(t2, 1.0, t2 * 0.45, cs), MeshAcc.limb(knee, foot), col, part, off, pv)
	if hi:
		a.add(MeshAcc.ball(t1 * 1.15, 5, 3), MeshAcc.xf(knee), col, part, off, pv)


static func _ell(a: MeshAcc, pos: Vector3, scl: Vector3, col: Color, part: int, hi: bool, rot := Vector3.ZERO, off := 0.0, pv := Vector2.ZERO) -> void:
	a.add(MeshAcc.ball(1.0, _seg(hi), _ring(hi)), MeshAcc.xf(pos, rot, scl), col, part, off, pv)


# ------------------------------------------------------------ strains

## Stalker (also the Brood Mother's body at scale k).
static func _stalker(a: MeshAcc, hi: bool, k: float, eye: Color) -> void:
	var hy := 0.42 * k
	# gaunt ribcage + pelvis, hunched spine ridge
	_ell(a, Vector3(0, hy, 0.05 * k), Vector3(0.17, 0.15, 0.32) * k, CHITIN, P.BODY, hi)
	_ell(a, Vector3(0, hy * 0.96, -0.32 * k), Vector3(0.13, 0.12, 0.17) * k, FLESH, P.BODY, hi)
	if hi:
		for r in 3:
			_ell(a, Vector3(0, hy - 0.02 * k, (0.2 - r * 0.12) * k), Vector3(0.18, 0.13, 0.025) * k, FLESH.darkened(0.3), P.BODY, false)
	for s in (5 if hi else 3):
		var z := (0.28 - s * 0.15) * k
		a.add(MeshAcc.cone(0.035 * k, 0.12 * k, 4), MeshAcc.xf(Vector3(0, hy + 0.14 * k, z), Vector3(-55, 0, 0)), DARK, P.BODY)
	# long low head with a long jaw
	var pv := Vector2(hy, 0.32 * k)
	a.add(MeshAcc.cyl(0.05 * k, 1.0, 0.04 * k, 5), MeshAcc.limb(Vector3(0, hy + 0.02 * k, 0.3 * k), Vector3(0, hy - 0.04 * k, 0.52 * k)), FLESH, P.HEAD, 0.0, pv)
	_ell(a, Vector3(0, hy - 0.03 * k, 0.62 * k), Vector3(0.085, 0.075, 0.16) * k, CHITIN, P.HEAD, hi, Vector3.ZERO, 0.0, pv)
	_ell(a, Vector3(0, hy - 0.05 * k, 0.83 * k), Vector3(0.055, 0.035, 0.14) * k, CHITIN, P.HEAD, hi, Vector3(-6, 0, 0), 0.0, pv)
	_ell(a, Vector3(0, hy - 0.11 * k, 0.78 * k), Vector3(0.05, 0.028, 0.13) * k, FLESH, P.HEAD, hi, Vector3(12, 0, 0), 0.0, pv)
	if hi:
		for t in 4:
			a.add(MeshAcc.cone(0.012 * k, 0.05 * k, 3), MeshAcc.xf(Vector3((t - 1.5) * 0.025 * k, hy - 0.085 * k, (0.86 + 0.02 * t) * k), Vector3(180, 0, 0)), BONE, P.HEAD, 0.0, pv)
	for e in 2:
		for sx: float in [-1.0, 1.0]:
			a.add(MeshAcc.ball(0.017 * k if e == 0 else 0.012 * k, 5, 3), MeshAcc.xf(Vector3(sx * (0.045 + 0.02 * e) * k, hy + 0.02 * k, (0.7 - 0.06 * e) * k)), eye, P.HEAD, 0.0, pv)
	# six thin legs, tripod gait (L1 R2 L3 together)
	for pair in 3:
		var z := (0.22 - pair * 0.24) * k
		for sx: float in [-1.0, 1.0]:
			var off := (0.0 if pair % 2 == 0 else PI) + (0.0 if sx < 0.0 else PI)
			var hip := Vector3(sx * 0.1 * k, hy, z)
			var knee := Vector3(sx * 0.32 * k, hy + 0.14 * k, z + 0.04 * k)
			var foot := Vector3(sx * 0.37 * k, 0.0, z + 0.1 * k)
			_limb(a, hip, knee, foot, 0.024 * k, 0.017 * k, CHITIN, P.LEG, off, hi)


static func _mauler(a: MeshAcc, hi: bool) -> void:
	var red := Color(0.75, 0.05, 0.04, 0.5)
	# front-heavy torso, small rear
	_ell(a, Vector3(0, 1.15, 0.3), Vector3(0.6, 0.55, 0.62), FLESH, P.BODY, hi)
	_ell(a, Vector3(0, 0.85, -0.6), Vector3(0.38, 0.35, 0.45), FLESH.darkened(0.15), P.BODY, hi)
	# plated shoulder shell with deep red markings
	_ell(a, Vector3(0, 1.5, 0.25), Vector3(0.78, 0.42, 0.72), CHITIN, P.SHELL, hi)
	for sx: float in [-1.0, 1.0]:
		_ell(a, Vector3(sx * 0.55, 1.32, 0.38), Vector3(0.26, 0.3, 0.45), CHITIN, P.SHELL, hi, Vector3(0, 0, sx * 20.0))
		a.add(MeshAcc.box(0.08, 0.05, 0.6), MeshAcc.xf(Vector3(sx * 0.28, 1.88, 0.25), Vector3(0, 0, sx * 18.0)), red, P.SHELL)
	a.add(MeshAcc.box(0.5, 0.05, 0.1), MeshAcc.xf(Vector3(0, 1.9, 0.5)), red, P.SHELL)
	if hi:
		for k in 3:
			_ell(a, Vector3(0, 1.32 - k * 0.12, -0.05 - k * 0.22), Vector3(0.48 - k * 0.07, 0.16, 0.2), CHITIN, P.SHELL, false)
	# low head under the shell, tusks, small red eyes
	var pv := Vector2(1.05, 0.75)
	_ell(a, Vector3(0, 0.98, 0.95), Vector3(0.24, 0.2, 0.25), CHITIN, P.HEAD, hi, Vector3.ZERO, 0.0, pv)
	for sx: float in [-1.0, 1.0]:
		a.add(MeshAcc.cone(0.045, 0.28, 4), MeshAcc.xf(Vector3(sx * 0.14, 0.86, 1.12), Vector3(60, 0, sx * -20.0)), BONE, P.HEAD, 0.0, pv)
		a.add(MeshAcc.ball(0.03, 5, 3), MeshAcc.xf(Vector3(sx * 0.1, 1.05, 1.15)), Color(1.0, 0.1, 0.05, GLOW), P.HEAD, 0.0, pv)
	# two club forelimbs (knuckle-walk), short hind legs
	for sx: float in [-1.0, 1.0]:
		var off := 0.0 if sx < 0.0 else PI
		var sh := Vector3(sx * 0.55, 1.3, 0.55)
		var el := Vector3(sx * 0.68, 0.72, 0.78)
		var wr := Vector3(sx * 0.64, 0.25, 0.85)
		var pvs := Vector2(sh.y, sh.z)
		a.add(MeshAcc.cyl(0.17, 1.0, 0.15, 6 if hi else 4), MeshAcc.limb(sh, el), FLESH, P.ARM, off, pvs)
		a.add(MeshAcc.cyl(0.16, 1.0, 0.2, 6 if hi else 4), MeshAcc.limb(el, wr), FLESH, P.ARM, off, pvs)
		_ell(a, wr + Vector3(0, -0.05, 0.02), Vector3(0.28, 0.24, 0.3), CHITIN, P.ARM, hi, Vector3.ZERO, off, pvs)
		if hi:
			for k in 3:
				a.add(MeshAcc.cone(0.05, 0.16, 4), MeshAcc.xf(wr + Vector3(sx * 0.12 - sx * k * 0.1, 0.12, 0.2), Vector3(-40, 0, 0)), BONE, P.ARM, off, pvs)
		_limb(a, Vector3(sx * 0.3, 0.82, -0.65), Vector3(sx * 0.4, 0.45, -0.5), Vector3(sx * 0.4, 0.0, -0.68), 0.13, 0.11, FLESH, P.LEG, PI - off, hi)


static func _spitter(a: MeshAcc, hi: bool) -> void:
	var acid := Color(0.35, 0.95, 0.08, 0.62)
	# tall thin body on four stilt legs
	_ell(a, Vector3(0, 1.45, 0.02), Vector3(0.14, 0.32, 0.15), CHITIN, P.BODY, hi, Vector3(8, 0, 0))
	_ell(a, Vector3(0, 1.1, -0.06), Vector3(0.17, 0.1, 0.19), FLESH, P.BODY, hi)
	a.add(MeshAcc.ball(0.11, 6, 4), MeshAcc.xf(Vector3(0, 1.5, -0.16)), acid, P.SAC, 0.7, Vector2(1.5, -0.16))
	# neck, small head, swollen translucent throat sac
	var pv := Vector2(1.72, 0.06)
	a.add(MeshAcc.cyl(0.04, 1.0, 0.035, 5), MeshAcc.limb(Vector3(0, 1.72, 0.05), Vector3(0, 1.95, 0.14)), FLESH, P.HEAD, 0.0, pv)
	_ell(a, Vector3(0, 2.0, 0.2), Vector3(0.08, 0.085, 0.13), CHITIN, P.HEAD, hi, Vector3.ZERO, 0.0, pv)
	for sx: float in [-1.0, 1.0]:
		a.add(MeshAcc.ball(0.015, 4, 2), MeshAcc.xf(Vector3(sx * 0.045, 2.03, 0.3)), acid, P.HEAD, 0.0, pv)
	a.add(MeshAcc.ball(0.17, 8 if hi else 5, 5 if hi else 3), MeshAcc.xf(Vector3(0, 1.78, 0.22), Vector3.ZERO, Vector3(1.0, 1.1, 1.0)), acid, P.SAC, 0.0, Vector2(1.78, 0.22))
	# four stilt legs, diagonal trot
	for fz: float in [1.0, -1.0]:
		for sx: float in [-1.0, 1.0]:
			var off := 0.0 if sx * fz > 0.0 else PI
			_limb(a, Vector3(sx * 0.11, 1.1, fz * 0.1), Vector3(sx * 0.36, 0.82, fz * 0.3), Vector3(sx * 0.44, 0.0, fz * 0.4), 0.032, 0.022, CHITIN, P.LEG, off, hi)


static func _snatcher(a: MeshAcc, hi: bool) -> void:
	var yel := Color(1.0, 0.85, 0.1, GLOW)
	# crouched lean torso pitched forward, yellow stripe + spines on the back
	_ell(a, Vector3(0, 1.0, 0.15), Vector3(0.15, 0.32, 0.12), CHITIN, P.BODY, hi, Vector3(52, 0, 0))
	_ell(a, Vector3(0, 0.76, -0.12), Vector3(0.13, 0.1, 0.13), FLESH, P.BODY, hi)
	var back := Basis.from_euler(Vector3(deg_to_rad(52), 0, 0))
	a.add(MeshAcc.box(0.07, 0.62, 0.03), Transform3D(back, Vector3(0, 1.0, 0.15) + back * Vector3(0, 0, -0.125)), yel, P.BODY)
	for s in (5 if hi else 3):
		var t := float(s) / 4.0
		var p := Vector3(0, 1.0, 0.15) + back * Vector3(0, lerpf(0.26, -0.24, t), -0.12)
		a.add(MeshAcc.cone(0.03, 0.16, 4), MeshAcc.xf(p, Vector3(-20, 0, 0)), DARK, P.BODY)
	# narrow head, yellow eyes
	var pv := Vector2(1.18, 0.38)
	_ell(a, Vector3(0, 1.17, 0.52), Vector3(0.085, 0.09, 0.15), CHITIN, P.HEAD, hi, Vector3(10, 0, 0), 0.0, pv)
	_ell(a, Vector3(0, 1.08, 0.64), Vector3(0.05, 0.03, 0.1), FLESH, P.HEAD, hi, Vector3.ZERO, 0.0, pv)
	for sx: float in [-1.0, 1.0]:
		a.add(MeshAcc.ball(0.028, 5, 3), MeshAcc.xf(Vector3(sx * 0.05, 1.2, 0.63)), yel, P.HEAD, 0.0, pv)
	# long arms with hooked claws, swinging like a sprinter's
	for sx: float in [-1.0, 1.0]:
		var off := PI if sx < 0.0 else 0.0
		var sh := Vector3(sx * 0.17, 1.18, 0.33)
		var el := Vector3(sx * 0.26, 0.7, 0.55)
		var wr := Vector3(sx * 0.26, 0.18, 0.7)
		var pvs := Vector2(sh.y, sh.z)
		a.add(MeshAcc.cyl(0.035, 1.0, 0.03, 5 if hi else 4), MeshAcc.limb(sh, el), CHITIN, P.ARM, off, pvs)
		a.add(MeshAcc.cyl(0.03, 1.0, 0.022, 5 if hi else 4), MeshAcc.limb(el, wr), CHITIN, P.ARM, off, pvs)
		for k in (3 if hi else 1):
			var tip := wr + Vector3(sx * (k - 1) * 0.035, -0.1, 0.18)
			a.add(MeshAcc.cone(0.018, 1.0, 4), MeshAcc.limb(wr + Vector3(sx * (k - 1) * 0.03, 0, 0), tip), BONE, P.ARM, off, pvs)
	# digitigrade legs
	for sx: float in [-1.0, 1.0]:
		var off := 0.0 if sx < 0.0 else PI
		var hip := Vector3(sx * 0.1, 0.75, -0.15)
		var pvl := Vector2(hip.y, hip.z)
		var knee := Vector3(sx * 0.13, 0.45, 0.1)
		var ank := Vector3(sx * 0.13, 0.16, -0.16)
		a.add(MeshAcc.cyl(0.045, 1.0, 0.035, 5 if hi else 4), MeshAcc.limb(hip, knee), CHITIN, P.LEG, off, pvl)
		a.add(MeshAcc.cyl(0.035, 1.0, 0.025, 5 if hi else 4), MeshAcc.limb(knee, ank), CHITIN, P.LEG, off, pvl)
		a.add(MeshAcc.cyl(0.025, 1.0, 0.015, 4), MeshAcc.limb(ank, Vector3(sx * 0.13, 0.0, 0.05)), DARK, P.LEG, off, pvl)


static func _burrower(a: MeshAcc, hi: bool) -> void:
	var amber := Color(1.0, 0.55, 0.08, 0.4)
	var zs := [0.75, 0.38, 0.0, -0.38, -0.74, -1.07]
	var rs := [0.3, 0.29, 0.27, 0.24, 0.2, 0.16]
	for k in zs.size():
		var z: float = zs[k]
		var r: float = rs[k]
		var off := float(k) * 0.9
		_ell(a, Vector3(0, r * 0.8, z), Vector3(r, r * 0.78, 0.22), CHITIN if k % 2 == 0 else FLESH, P.SEG, hi, Vector3.ZERO, off)
		if hi:
			_ell(a, Vector3(0, r * 1.45, z), Vector3(r * 0.7, r * 0.18, 0.16), DARK, P.SEG, false, Vector3.ZERO, off)
		if k < zs.size() - 1:
			# amber glow seeping between the segments
			var zm := (z + float(zs[k + 1])) * 0.5
			a.add(MeshAcc.cyl(r * 0.82, 0.07, -1.0, 8 if hi else 5), MeshAcc.xf(Vector3(0, r * 0.78, zm), Vector3(90, 0, 0)), amber, P.SEG, off + 0.45)
	# drill-tooth maw ringed with teeth, no eyes
	a.add(MeshAcc.cyl(0.2, 0.06, -1.0, 8), MeshAcc.xf(Vector3(0, 0.25, 1.0), Vector3(90, 0, 0)), DARK, P.SEG, 0.0)
	for t in (8 if hi else 5):
		var ang := TAU * t / (8.0 if hi else 5.0)
		var p := Vector3(cos(ang) * 0.2, 0.25 + sin(ang) * 0.17, 1.0)
		var b := Basis.looking_at(Vector3(-cos(ang) * 0.4, -sin(ang) * 0.4, 1.0).normalized(), Vector3.UP)
		a.add(MeshAcc.cone(0.04, 0.17, 4), Transform3D(b * Basis.from_euler(Vector3(-PI * 0.5, 0, 0)), p), BONE, P.SEG, 0.0)


static func _mother(a: MeshAcc, hi: bool) -> void:
	var mag := Color(1.0, 0.2, 0.75, 0.35)
	_stalker(a, hi, 2.6, Color(1.0, 0.2, 0.75, GLOW))
	# bloated egg-sac abdomen
	var c := Vector3(0, 1.4, -1.75)
	_ell(a, c, Vector3(1.0, 0.85, 1.35), FLESH.lerp(Color(0.3, 0.12, 0.22), 0.5), P.SAC, hi, Vector3(-8, 0, 0), 0.0, Vector2(c.y, c.z))
	var spots := [Vector3(0.6, 1.7, -1.4), Vector3(-0.65, 1.55, -1.9), Vector3(0.25, 2.05, -2.0), Vector3(-0.3, 1.1, -2.7), Vector3(0.7, 1.1, -2.3), Vector3(0.0, 1.85, -1.15)]
	for k in (spots.size() if hi else 3):
		a.add(MeshAcc.ball(0.2, 6, 3), MeshAcc.xf(spots[k]), mag, P.SAC, float(k), Vector2(c.y, c.z))
	# crown of horns
	var hy := 0.42 * 2.6
	var pv := Vector2(hy, 0.32 * 2.6)
	for k in (7 if hi else 4):
		var ang := -70.0 + k * (140.0 / (6.0 if hi else 3.0))
		var p := Vector3(sin(deg_to_rad(ang)) * 0.2, hy + 0.16, 0.55 * 2.6 + cos(deg_to_rad(ang)) * 0.05 - 0.15)
		a.add(MeshAcc.cone(0.05, 0.5, 4), MeshAcc.xf(p, Vector3(-35, 0, -ang * 0.7)), BONE, P.HEAD, 0.0, pv)
