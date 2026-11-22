class_name AlienMeshes
extends RefCounted
## The swarm, per concept sheet "predatory/primal - HUMANOID LINEUP v3":
## gaunt faceted bipeds in charcoal with an olive front panel, bone-white
## claws, and one glowing identity colour each.
##   Stalker   hunched, long jaw, black back spikes, long arms  | white eye
##             (Brood Mother young are Stalker "runts")
##   Mauler    gorilla build, boulder shoulders/head with red slashes, huge
##             rock fists it knuckle-walks on, white fang     | red eye + marks
##   Spitter   upright, black back spikes, swollen throat sac; hunches and
##             spits when attacking                           | green sac + eyes
##   Snatcher  very long arms dragging white claws, yellow spines | yellow eyes
##   Burrower  no legs: segmented torso with orange glow between segments,
##             circular orange-toothed maw, breaches from a dirt mound | orange
##   Brood Mother  tall, carries a faceted purple egg sac with magenta glowing
##             spots and clinging young, crown of white spikes | magenta
##   Mauler Elder  (v4) a Mauler with old spears jutting from its back and
##             fresh wounds                                   | red
##   Stalker Runt  (v4) a small Stalker: the Brood Mother's young  | white
## Vertices carry part / phase / joint pivot for alien.gdshader. Built twice:
## lod 0 (near) and lod 1 (far). Flat-shaded for the faceted look.

const BLACK := Color("1c1c1a")
const DARK := Color("2b2c29")
const MID := Color("4b4f4c")
const LIGHT := Color("7d817b")
const OLIVE := Color("6e6b3f")
const OLIVE_L := Color("8f8a52")
const BONE := Color("e8e4d6")
const DIRT := Color("4a3522")
const DIRT_D := Color("3e2c1c")
const SAC_D := Color("3a2433")
const SAC_L := Color("6b4256")

enum P { BODY, HEAD, THIGH, ARM, SEG, SAC, TAIL, STATIC, PLATE, SHIN, FOREARM, MOUND, YOUNG }

const YOUNG_N := 8   # young modelled on the Brood Mother's sac (shader shows as many as she carries)


## Which body plan a strain uses (v4 variants share their parent's).
static func base_id(id: String) -> String:
	match id:
		"elder": return "mauler"
		"runt": return "stalker"
	return id


## Height of the authored model in metres (standing). GameConfig scales each
## strain to its concept-sheet SIZE rating from this.
static func authored_height(id: String) -> float:
	match base_id(id):
		"mauler": return 2.22
		"burrower": return 1.53
	var c := _cfg(id)
	var hd: Vector3 = c.head
	var hs: Vector3 = c.head_s
	return hd.y + hs.y


static func _cfg(id: String) -> Dictionary:
	match base_id(id):
		"stalker":
			return {"hip": Vector3(0.08, 0.74, -0.05), "knee": Vector3(0.1, 0.42, 0.14), "ankle": Vector3(0.1, 0.08, -0.06), "toe": Vector3(0.1, 0.0, 0.08),
				"leg_t": 0.05, "shin_t": 0.038, "t_base": Vector3(0, 0.72, -0.04), "t_top": Vector3(0, 1.06, 0.26), "t_w": 0.12, "t_d": 0.1,
				"shoulder": Vector3(0.12, 1.03, 0.22), "elbow": Vector3(0.15, 0.7, 0.3), "wrist": Vector3(0.15, 0.4, 0.26), "arm_t": 0.035, "fore_t": 0.03, "claw": 0.1,
				"neck": Vector3(0, 1.12, 0.36), "head": Vector3(0, 1.15, 0.43), "head_s": Vector3(0.075, 0.07, 0.1), "muzzle": Vector3(0, 1.11, 0.54), "muzzle_s": Vector3(0.045, 0.035, 0.09),
				"eye": Color(0.93, 0.91, 0.84, 0.0), "eye_p": Vector3(0.04, 1.17, 0.5), "eye_r": 0.017, "spikes": 6, "spike_col": BLACK, "spike_s": 0.11,
				"q": [0.05, 0.9, 0.5, 0.85, 0.35], "gait": 11.0}
		"mauler":
			return {"hip": Vector3(0.24, 0.85, -0.25), "knee": Vector3(0.28, 0.45, -0.1), "ankle": Vector3(0.28, 0.08, -0.25), "toe": Vector3(0.28, 0.0, -0.02),
				"leg_t": 0.14, "shin_t": 0.12, "t_base": Vector3(0, 0.82, -0.25), "t_top": Vector3(0, 1.72, 0.08), "t_w": 0.42, "t_d": 0.32,
				"shoulder": Vector3(0.5, 1.66, 0.05), "elbow": Vector3(0.66, 1.05, 0.15), "wrist": Vector3(0.66, 0.42, 0.25), "arm_t": 0.16, "fore_t": 0.15, "claw": 0.0,
				"neck": Vector3(0, 1.72, 0.22), "head": Vector3(0, 1.7, 0.36), "head_s": Vector3(0.15, 0.13, 0.14), "muzzle": Vector3(0, 1.62, 0.46), "muzzle_s": Vector3(0.1, 0.07, 0.08),
				"eye": Color(1.0, 0.15, 0.12, 0.0), "eye_p": Vector3(0.06, 1.75, 0.48), "eye_r": 0.03, "spikes": 0,
				"q": [0.25, 0.55, 0.3, 0.85, 0.0], "gait": 5.5}
		"spitter":
			return {"hip": Vector3(0.08, 0.78, -0.02), "knee": Vector3(0.1, 0.45, 0.1), "ankle": Vector3(0.1, 0.08, -0.06), "toe": Vector3(0.1, 0.0, 0.08),
				"leg_t": 0.045, "shin_t": 0.035, "t_base": Vector3(0, 0.76, -0.02), "t_top": Vector3(0, 1.32, 0.04), "t_w": 0.12, "t_d": 0.1,
				"shoulder": Vector3(0.12, 1.3, 0.04), "elbow": Vector3(0.15, 1.05, 0.13), "wrist": Vector3(0.13, 0.86, 0.18), "arm_t": 0.032, "fore_t": 0.028, "claw": 0.13,
				"neck": Vector3(0, 1.45, 0.08), "head": Vector3(0, 1.53, 0.12), "head_s": Vector3(0.07, 0.07, 0.09), "muzzle": Vector3(0, 1.5, 0.2), "muzzle_s": Vector3(0.04, 0.03, 0.06),
				"eye": Color(0.25, 0.85, 0.23, 0.0), "eye_p": Vector3(0.035, 1.55, 0.18), "eye_r": 0.016, "spikes": 5, "spike_col": BLACK, "spike_s": 0.1,
				"q": [0.0, 0.2, 0.6, 0.9, 0.6], "gait": 8.0}
		"snatcher":
			return {"hip": Vector3(0.08, 0.86, -0.05), "knee": Vector3(0.1, 0.48, 0.12), "ankle": Vector3(0.1, 0.08, -0.06), "toe": Vector3(0.1, 0.0, 0.08),
				"leg_t": 0.045, "shin_t": 0.035, "t_base": Vector3(0, 0.84, -0.05), "t_top": Vector3(0, 1.45, 0.12), "t_w": 0.12, "t_d": 0.1,
				"shoulder": Vector3(0.13, 1.42, 0.1), "elbow": Vector3(0.17, 0.85, 0.16), "wrist": Vector3(0.19, 0.22, 0.2), "arm_t": 0.032, "fore_t": 0.027, "claw": 0.2,
				"neck": Vector3(0, 1.52, 0.17), "head": Vector3(0, 1.6, 0.22), "head_s": Vector3(0.07, 0.07, 0.09), "muzzle": Vector3(0, 1.57, 0.3), "muzzle_s": Vector3(0.04, 0.03, 0.06),
				"eye": Color(0.89, 0.76, 0.11, 0.0), "eye_p": Vector3(0.035, 1.62, 0.28), "eye_r": 0.018, "spikes": 7, "spike_col": Color(0.89, 0.76, 0.11, 0.55), "spike_s": 0.14,
				"q": [0.05, 0.75, 0.5, 0.8, 0.3], "gait": 9.0}
		"burrower":
			return {"legs": false, "hip": Vector3(0.0, 0.65, 0.0), "t_base": Vector3(0, 0.86, 0.0), "t_top": Vector3(0, 1.2, 0.06), "t_w": 0.16, "t_d": 0.12,
				"shoulder": Vector3(0.15, 1.15, 0.06), "elbow": Vector3(0.3, 0.88, 0.16), "wrist": Vector3(0.28, 0.62, 0.26), "arm_t": 0.04, "fore_t": 0.035, "claw": 0.09,
				"neck": Vector3(0, 1.24, 0.07), "eye_r": 0.0, "spikes": 0, "sink": 1.05,
				"q": [0.0, 0.15, 0.5, 0.9, 0.25], "gait": 8.0}
		"brood_mother":
			return {"hip": Vector3(0.12, 1.25, -0.05), "knee": Vector3(0.15, 0.7, 0.2), "ankle": Vector3(0.15, 0.1, -0.08), "toe": Vector3(0.15, 0.0, 0.12),
				"leg_t": 0.08, "shin_t": 0.065, "t_base": Vector3(0, 1.23, -0.05), "t_top": Vector3(0, 2.05, 0.18), "t_w": 0.2, "t_d": 0.16,
				"shoulder": Vector3(0.2, 2.0, 0.15), "elbow": Vector3(0.26, 1.45, 0.26), "wrist": Vector3(0.26, 0.95, 0.3), "arm_t": 0.055, "fore_t": 0.045, "claw": 0.16,
				"neck": Vector3(0, 2.15, 0.25), "head": Vector3(0, 2.25, 0.32), "head_s": Vector3(0.12, 0.11, 0.14), "muzzle": Vector3(0, 2.2, 0.44), "muzzle_s": Vector3(0.07, 0.05, 0.08),
				"eye": Color(0.83, 0.17, 0.71, 0.0), "eye_p": Vector3(0.06, 2.28, 0.42), "eye_r": 0.026, "spikes": 0,
				"q": [0.1, 0.35, 0.4, 0.9, 0.2], "gait": 3.5}
	return _cfg("stalker")


## Shader uniforms + stride rate per strain.
static func rig(id: String) -> Dictionary:
	var c := _cfg(id)
	var hip: Vector3 = c.hip
	var sh: Vector3 = c.shoulder
	var wr: Vector3 = c.wrist
	var reach := sh.y - wr.y + float(c.claw) * 0.6
	# pitch so the hands reach the ground on all fours; crouch the rest
	var pitch := 1.35
	var shoulder_h := 0.0
	for k in 28:
		var p := k * 0.05
		shoulder_h = hip.y + (sh.y - hip.y) * cos(p) - (sh.z - hip.z) * sin(p)
		if shoulder_h - reach <= 0.06:
			pitch = p
			break
	var final_h := hip.y + (sh.y - hip.y) * cos(pitch) - (sh.z - hip.z) * sin(pitch)
	var q: Array = c.q
	var dead := {"stalker": [1.1, 0.4, 0.0, 0.05, 0.95], "mauler": [0.5, 0.8, 0.0, 0.0, 10.0], "spitter": [0.8, 0.5, 0.0, 0.0, 10.0],
		"snatcher": [0.3, 0.0, 0.0, 0.0, 10.0], "burrower": [0.0, 0.6, 0.32, 0.0, 10.0], "brood_mother": [0.9, 0.5, 0.0, 0.0, 10.0]}
	var b := base_id(id)
	var dd: Array = dead.get(b, [1.0, 0.0, 0.0, 0.0, 10.0])
	var tells := {"spitter": 1, "burrower": 2, "mauler": 3, "elder": 4}
	var acts := {"mauler": 2, "snatcher": 1}
	return {
		"hip_y": hip.y, "hip_z": hip.z, "sh_y": sh.y, "sh_z": sh.z, "pitch_max": pitch,
		"q_min": q[0], "q_max": q[1], "run_lo": q[2], "run_hi": q[3], "attack_q": q[4],
		"quad_drop": maxf(0.0, final_h - reach - 0.06) * 0.6,
		"leg_amp": 0.5 if b != "mauler" else 0.35, "knee_amp": 0.8, "arm_amp": 0.5 if b != "mauler" else 0.45,
		"sink": float(c.get("sink", 0.0)), "dead_curl": dd[0], "dead_arm": dd[1], "seg_gap": dd[2], "split": dd[3], "split_y": dd[4],
		"sheen": 0.35, "gait_freq": float(c.gait),
		# v4 behaviour poses: tell 1 sac inflate / 2 ground breach / 3 charge
		# wind-up / 4 roar; act 1 drag backward / 2 shoulder charge
		"tell_kind": int(tells.get(id, 0)), "act_kind": int(acts.get(id, 0)),
		"twitch": 1.0 if b == "stalker" else 0.0, "sac_drain": 1.0 if b == "spitter" else 0.0,
		"young_n": float(YOUNG_N) if b == "brood_mother" else 0.0,
		# faint identity-coloured rim so each strain reads against the ground
		"rim_col": _identity(id),
	}


static func _identity(id: String) -> Color:
	match base_id(id):
		"mauler": return Color(0.9, 0.15, 0.12)
		"spitter": return Color(0.3, 0.9, 0.25)
		"snatcher": return Color(0.95, 0.78, 0.15)
		"burrower": return Color(1.0, 0.5, 0.1)
		"brood_mother": return Color(0.85, 0.2, 0.75)
	return Color(0.85, 0.82, 0.74)


## How the corpse lies: "side", "back", "face" (face-first) or "flat".
static func corpse_pose(id: String) -> String:
	match base_id(id):
		"snatcher": return "back"
		"mauler", "burrower", "brood_mother": return "face"
	return "side"


## Body colours per strain (reference art "aliens in the field"): olive
## Spitters, purple Brood Mothers, stone-brown Maulers and Elders, dark-brown
## Burrowers, charcoal Stalkers and Snatchers.
static func _palette(id: String) -> Dictionary:
	match id:
		"spitter": return {"cb": Color("6a6436"), "cl": Color("3e3b22"), "cp": Color("a49c5c")}
		"brood_mother": return {"cb": Color("43304f"), "cl": Color("2a1e33"), "cp": Color("6b4a80")}
		"mauler": return {"cb": Color("4a433d"), "cl": Color("332e2a"), "cp": Color("5f554c")}
		"elder": return {"cb": Color("3f3934"), "cl": Color("2b2724"), "cp": Color("554c44")}
		"burrower": return {"cb": Color("3a2c24"), "cl": Color("261d18"), "cp": Color("6e5238")}
		"snatcher": return {"cb": Color("2d2c30"), "cl": Color("1b1a1d"), "cp": Color("8f8a52")}
	return {"cb": Color("332f2a"), "cl": Color("1f1d1a"), "cp": OLIVE_L}


static func build(id: String, lod := 0) -> ArrayMesh:
	var a := MeshAcc.new()
	var hi := lod == 0
	var c := _cfg(id)
	c.merge(_palette(id), true)
	_humanoid(a, c, hi)
	match base_id(id):
		"mauler": _mauler(a, c, hi)
		"spitter": _spitter(a, c, hi)
		"burrower": _burrower(a, c, hi)
		"brood_mother": _mother(a, c, hi)
	if id == "elder":
		_elder(a, c, hi)
	return a.commit(true)


# ------------------------------------------------------------ builders

static func _prism(a: MeshAcc, from: Vector3, to: Vector3, r0: float, r1: float, col: Color, part: int, off: float, pv: Vector2, sides := 5, depth := 1.0) -> void:
	a.add(MeshAcc.cyl(r0, 1.0, r1, sides), MeshAcc.limb(from, to, Vector3(1.0, 1.0, depth)), col, part, off, pv)


static func _rock(a: MeshAcc, pos: Vector3, r: float, col: Color, part: int, off: float, pv: Vector2, hi: bool, seed_v: int) -> void:
	var start := a.v.size()
	a.add(MeshAcc.ball(r, 5 if hi else 4, 3 if hi else 2), MeshAcc.xf(pos), col, part, off, pv)
	a.jitter(start, r * 0.22, seed_v)


static func _humanoid(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var sides := 5 if hi else 4
	var cb: Color = c.get("cb", DARK)
	var cl: Color = c.get("cl", BLACK)
	var cp: Color = c.get("cp", OLIVE_L)
	var tb: Vector3 = c.t_base
	var tt: Vector3 = c.t_top
	var tw: float = c.t_w
	var td: float = c.t_d
	var axis := (tt - tb).normalized()
	var front := Vector3(0, -axis.z, axis.y).normalized()
	# torso: tapered charcoal prism with an olive front panel
	_prism(a, tb, tt, tw * 0.75, tw, cb, P.BODY, 0.0, Vector2.ZERO, 6 if hi else 4, td / tw)
	_prism(a, tb + front * td * 0.6 + axis * 0.03, tt + front * td * 0.6 - axis * 0.05, tw * 0.42, tw * 0.62, cp, P.BODY, 0.0, Vector2.ZERO, 4, 0.3)
	_prism(a, tb - axis * 0.06, tb + axis * 0.08, tw * 0.6, tw * 0.75, cl, P.BODY, 0.0, Vector2.ZERO, sides)
	# back spikes
	var n_sp := int(c.get("spikes", 0))
	for k in (n_sp if hi else mini(n_sp, 3)):
		var t := (k + 0.5) / float(n_sp if hi else mini(n_sp, 3))
		var p := tb.lerp(tt, 0.15 + 0.8 * t) - front * td * 0.8
		var dir := (-front * 0.8 + axis * 0.6).normalized()
		var ss: float = c.get("spike_s", 0.1) * (0.7 + 0.5 * sin(t * PI))
		a.add(MeshAcc.cone(ss * 0.28, 1.0, 4), MeshAcc.limb(p, p + dir * ss), c.get("spike_col", cl), P.BODY)
	if hi and c.get("legs", true):
		# spine: a ridge of vertebrae down the back
		for k in 6:
			var t := (k + 0.5) / 6.0
			var p := tb.lerp(tt, 0.06 + 0.9 * t) - front * td * 0.92
			a.add(MeshAcc.ball(tw * 0.14, 4, 2), MeshAcc.xf(p, Vector3.ZERO, Vector3(1.0, 0.75, 1.25)), cl, P.BODY)
		# rib bands wrapping the flanks
		var side := axis.cross(front).normalized()
		for k in 3:
			var p := tb.lerp(tt, 0.38 + k * 0.17)
			for sx: float in [-1.0, 1.0]:
				var sp := p + side * sx * tw * 0.9
				a.add(MeshAcc.cyl(0.011 + tw * 0.06, 1.0, 0.008 + tw * 0.05, 4), MeshAcc.limb(sp - front * td * 0.85, sp + front * td * 0.55), MID, P.BODY)
	# arms: shoulder -> elbow -> wrist, bone-white claws
	var sh: Vector3 = c.shoulder
	var el: Vector3 = c.elbow
	var wr: Vector3 = c.wrist
	for sx: float in [-1.0, 1.0]:
		var off := PI if sx < 0.0 else 0.0
		var S := Vector3(sx * sh.x, sh.y, sh.z)
		var E := Vector3(sx * el.x, el.y, el.z)
		var W := Vector3(sx * wr.x, wr.y, wr.z)
		_prism(a, S, E, c.arm_t, c.arm_t * 0.8, cb, P.ARM, off, Vector2(sh.y, sh.z), sides)
		_prism(a, E, W, c.fore_t, c.fore_t * 0.7, cl, P.FOREARM, off, Vector2(el.y, el.z), sides)
		if hi:
			# knobbed elbow and a faceted shoulder plate
			var at: float = c.arm_t
			a.add(MeshAcc.ball(at * 1.25, 4, 3), MeshAcc.xf(E), cl, P.ARM, off, Vector2(sh.y, sh.z))
			var start := a.v.size()
			a.add(MeshAcc.ball(1.0, 5, 3), MeshAcc.xf(S + Vector3(sx * at * 0.4, at * 0.8, -at * 0.3), Vector3(0, 0, sx * 20.0), Vector3(at * 2.0, at * 1.2, at * 2.3)), cb, P.BODY)
			a.jitter(start, at * 0.35, 13 + int(sx))
		var clw: float = c.claw
		if clw > 0.0:
			for k in (3 if hi else 1):
				var ofs := Vector3(sx * (k - 1) * 0.02, 0, 0)
				a.add(MeshAcc.cone(clw * 0.12, 1.0, 3), MeshAcc.limb(W + ofs, W + ofs + Vector3(sx * (k - 1) * 0.02, -clw, clw * 0.35)), BONE, P.FOREARM, off, Vector2(el.y, el.z))
	# legs: hip -> knee -> ankle -> toe
	if c.get("legs", true):
		var hp: Vector3 = c.hip
		var kn: Vector3 = c.knee
		var an: Vector3 = c.ankle
		var to: Vector3 = c.toe
		for sx: float in [-1.0, 1.0]:
			var off := 0.0 if sx < 0.0 else PI
			var H := Vector3(sx * hp.x, hp.y, hp.z)
			var K := Vector3(sx * kn.x, kn.y, kn.z)
			var A := Vector3(sx * an.x, an.y, an.z)
			var T := Vector3(sx * to.x, to.y, to.z)
			_prism(a, H, K, c.leg_t, c.leg_t * 0.8, cb, P.THIGH, off, Vector2(hp.y, hp.z), sides)
			_prism(a, K, A, c.shin_t, c.shin_t * 0.7, cl, P.SHIN, off, Vector2(kn.y, kn.z), sides)
			_prism(a, A, T, c.shin_t * 0.8, c.shin_t * 0.5, cl, P.SHIN, off, Vector2(kn.y, kn.z), 4)
			if hi:
				# knobbed knee, two hooked toe claws
				a.add(MeshAcc.ball(float(c.leg_t) * 1.2, 4, 3), MeshAcc.xf(K), cl, P.THIGH, off, Vector2(hp.y, hp.z))
				for tc: float in [-1.0, 1.0]:
					var tp := T + Vector3(tc * float(c.shin_t) * 0.6, 0.0, 0.0)
					a.add(MeshAcc.cone(float(c.shin_t) * 0.3, 1.0, 3), MeshAcc.limb(tp, tp + Vector3(tc * 0.015, -0.012, 0.075)), BONE, P.SHIN, off, Vector2(kn.y, kn.z))
	# neck + head (skull, long muzzle, glowing eyes, teeth)
	if c.has("head"):
		var nk: Vector3 = c.neck
		var hd: Vector3 = c.head
		var pv := Vector2(tt.y, tt.z)
		_prism(a, tt, nk, tw * 0.3, tw * 0.25, cb, P.HEAD, 0.0, pv, 4)
		var hs: Vector3 = c.head_s
		a.add(MeshAcc.ball(1.0, 6 if hi else 4, 4 if hi else 3), MeshAcc.xf(hd, Vector3.ZERO, hs), cb, P.HEAD, 0.0, pv)
		var ms: Vector3 = c.muzzle_s
		a.add(MeshAcc.ball(1.0, 5 if hi else 4, 3 if hi else 2), MeshAcc.xf(c.muzzle, Vector3(-8, 0, 0), ms), cl, P.HEAD, 0.0, pv)
		var er: float = c.get("eye_r", 0.0)
		if er > 0.0:
			var ep: Vector3 = c.eye_p
			for sx: float in [-1.0, 1.0]:
				a.add(MeshAcc.ball(er, 4, 2), MeshAcc.xf(Vector3(sx * ep.x, ep.y, ep.z)), c.eye, P.HEAD, 0.0, pv)
		if hi:
			var mz: Vector3 = c.muzzle
			# upper fangs, a hinged lower jaw with its own teeth, a heavy brow
			for t in 5:
				var tx := (t - 2) * ms.x * 0.32
				a.add(MeshAcc.cone(ms.x * (0.2 if t % 2 == 0 else 0.14), ms.y * (1.7 if t % 2 == 0 else 1.1), 3), MeshAcc.xf(Vector3(tx, mz.y - ms.y * 0.7, mz.z + ms.z * 0.5 - absf(tx) * 0.6), Vector3(180, 0, 0)), BONE, P.HEAD, 0.0, pv)
			var jaw := mz + Vector3(0, -ms.y * 1.5, -ms.z * 0.25)
			a.add(MeshAcc.box(ms.x * 1.5, ms.y * 0.6, ms.z * 1.7), MeshAcc.xf(jaw, Vector3(12, 0, 0)), cl, P.HEAD, 0.0, pv)
			for t in 3:
				a.add(MeshAcc.cone(ms.x * 0.13, ms.y * 0.9, 3), MeshAcc.xf(jaw + Vector3((t - 1) * ms.x * 0.4, ms.y * 0.45, ms.z * 0.55)), BONE, P.HEAD, 0.0, pv)
			if er > 0.0:
				var ep: Vector3 = c.eye_p
				a.add(MeshAcc.box(ep.x * 2.8, er * 1.4, er * 3.0), MeshAcc.xf(Vector3(0, ep.y + er * 1.6, ep.z - er * 0.4), Vector3(-18, 0, 0)), cl, P.HEAD, 0.0, pv)


static func _mauler(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var seam := Color(1.0, 0.12, 0.05, 0.05)
	var stone: Color = c.get("cp", MID)
	var stone_d: Color = c.get("cb", DARK)
	var spike := Color("c2b8aa")
	var tt: Vector3 = c.t_top
	var pv := Vector2(tt.y, tt.z)
	# blocky stone plates on shoulders, crown, chest and belly; each with a
	# glowing red seam (they crack off on death)
	var plates := [[Vector3(-0.47, 1.82, 0.0), Vector3(0.44, 0.38, 0.5), Vector3(0, 0, 16)],
		[Vector3(0.47, 1.82, 0.0), Vector3(0.44, 0.38, 0.5), Vector3(0, 0, -16)],
		[Vector3(0.0, 1.97, -0.06), Vector3(0.52, 0.3, 0.44), Vector3(-8, 0, 0)],
		[Vector3(0.0, 1.5, 0.22), Vector3(0.52, 0.4, 0.14), Vector3(-14, 0, 0)],
		[Vector3(0.0, 1.14, 0.18), Vector3(0.42, 0.3, 0.12), Vector3(-6, 0, 0)]]
	for k in (plates.size() if hi else 3):
		var pos: Vector3 = plates[k][0]
		var sz: Vector3 = plates[k][1]
		var rot: Vector3 = plates[k][2]
		a.add_bevel_box(sz, MeshAcc.xf(pos, rot), stone if k % 2 == 0 else stone.darkened(0.12), 0.06, P.PLATE, 0.0, pv)
		var b := Basis.from_euler(rot * (PI / 180.0))
		a.add(MeshAcc.box(sz.x * 0.7, 0.03, 0.02), Transform3D(b, pos + b * Vector3(0, sz.y * 0.1, sz.z * 0.5 + 0.004)), seam, P.PLATE, 0.0, pv)
		if hi and k < 3:
			a.add(MeshAcc.box(0.03, sz.y * 0.6, 0.02), Transform3D(b, pos + b * Vector3(sz.x * 0.22, -sz.y * 0.1, sz.z * 0.5 + 0.004)), seam, P.PLATE, 0.0, pv)
	# bone spikes along the shoulders and back
	var spikes := [[Vector3(-0.55, 1.98, -0.05), Vector3(-0.75, 2.35, -0.2)], [Vector3(0.55, 1.98, -0.05), Vector3(0.75, 2.35, -0.2)],
		[Vector3(-0.15, 2.1, -0.15), Vector3(-0.22, 2.5, -0.35)], [Vector3(0.15, 2.1, -0.15), Vector3(0.22, 2.5, -0.35)], [Vector3(0.0, 1.8, -0.3), Vector3(0.0, 2.15, -0.65)]]
	for k in (spikes.size() if hi else 2):
		a.add(MeshAcc.cone(0.06, 1.0, 5), MeshAcc.limb(spikes[k][0], spikes[k][1]), spike, P.PLATE, 0.0, pv)
	# stone fists (clubs it walks on) and forearm guards, seams glowing
	var wr: Vector3 = c.wrist
	var el: Vector3 = c.elbow
	for sx: float in [-1.0, 1.0]:
		var off := PI if sx < 0.0 else 0.0
		var fpv := Vector2(el.y, el.z)
		var W := Vector3(sx * wr.x, wr.y, wr.z)
		var E := Vector3(sx * el.x, el.y, el.z)
		a.add_bevel_box(Vector3(0.36, 0.34, 0.4), MeshAcc.xf(W + Vector3(0, -0.12, 0.03), Vector3(0, sx * 8.0, 0)), stone, 0.07, P.FOREARM, off, fpv)
		a.add(MeshAcc.box(0.26, 0.03, 0.02), MeshAcc.xf(W + Vector3(0, -0.08, 0.235)), seam, P.FOREARM, off, fpv)
		if hi:
			for k in 3:
				a.add_bevel_box(Vector3(0.09, 0.09, 0.08), MeshAcc.xf(W + Vector3(-0.11 + k * 0.11, -0.2, 0.24)), stone_d, 0.02, P.FOREARM, off, fpv)
			a.add_bevel_box(Vector3(0.24, 0.42, 0.22), MeshAcc.xf((E + W) * 0.5 + Vector3(sx * 0.03, 0.06, 0.06), Vector3(0, 0, sx * 8.0)), stone.darkened(0.08), 0.05, P.FOREARM, off, fpv)
			a.add(MeshAcc.box(0.03, 0.3, 0.02), MeshAcc.xf((E + W) * 0.5 + Vector3(sx * 0.03, 0.06, 0.175)), seam, P.FOREARM, off, fpv)
	# white fang and two tusks
	var mz: Vector3 = c.muzzle
	a.add(MeshAcc.cone(0.035, 0.16, 4), MeshAcc.xf(mz + Vector3(0.05, -0.08, 0.05), Vector3(180, 0, 0)), BONE, P.HEAD, 0.0, pv)
	for sx: float in [-1.0, 1.0]:
		a.add(MeshAcc.cone(0.03, 1.0, 4), MeshAcc.limb(mz + Vector3(sx * 0.08, -0.06, 0.02), mz + Vector3(sx * 0.13, 0.06, 0.12)), BONE, P.HEAD, 0.0, pv)


## Elder: old spears and broken shafts jutting from the back and shoulders,
## and fresh red wounds across the chest.
static func _elder(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var tt: Vector3 = c.t_top
	var pv := Vector2(tt.y, tt.z)
	var shaft := Color("3a3b38")
	var spears := [[Vector3(-0.32, 1.78, -0.22), Vector3(-0.48, 2.95, -0.55)], [Vector3(-0.12, 1.86, -0.28), Vector3(-0.16, 3.15, -0.62)],
		[Vector3(0.1, 1.84, -0.28), Vector3(0.18, 2.85, -0.7)], [Vector3(0.3, 1.76, -0.22), Vector3(0.52, 2.7, -0.42)],
		[Vector3(0.0, 1.55, -0.32), Vector3(0.04, 2.45, -0.95)], [Vector3(-0.46, 1.62, -0.1), Vector3(-0.85, 2.4, -0.2)]]
	for k in (spears.size() if hi else 3):
		var from: Vector3 = spears[k][0]
		var to: Vector3 = spears[k][1]
		a.add(MeshAcc.cone(0.05 if k % 2 == 0 else 0.04, 1.0, 4), MeshAcc.limb(from, to), BLACK if k % 3 == 0 else shaft, P.PLATE, 0.0, pv)
	var red := Color(0.78, 0.13, 0.12, 0.45)
	var cuts := [Vector3(0.12, 1.45, 0.2), Vector3(-0.15, 1.25, 0.18), Vector3(0.22, 1.1, 0.12), Vector3(-0.05, 1.6, 0.17)]
	for k in (cuts.size() if hi else 2):
		a.add(MeshAcc.box(0.2, 0.035, 0.04), MeshAcc.xf(cuts[k], Vector3(-35, 0, 25.0 - k * 22.0)), red, P.BODY, 0.0, Vector2.ZERO)


static func _spitter(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var acid := Color(0.3, 0.9, 0.2, 0.25)
	var tt: Vector3 = c.t_top
	var sac := Vector3(0, tt.y + 0.01, tt.z + 0.14)
	var spv := Vector2(sac.y, sac.z)
	# swollen glowing sac with dark plated ribs around it
	var start := a.v.size()
	a.add(MeshAcc.ball(0.16, 7 if hi else 4, 5 if hi else 3), MeshAcc.xf(sac, Vector3.ZERO, Vector3(1.0, 1.05, 0.95)), acid, P.SAC, 0.0, spv)
	a.jitter(start, 0.012, 21)
	if hi:
		for k in 3:
			a.add(MeshAcc.cyl(0.165 - absf(k - 1) * 0.04, 0.022, -1.0, 10), MeshAcc.xf(sac + Vector3(0, (k - 1) * 0.09, 0), Vector3(0, 0, 0), Vector3(1.0, 1.0, 0.95)), c.get("cl", BLACK), P.SAC, 0.0, spv)
		a.add(MeshAcc.cyl(0.012, 0.3, -1.0, 4), MeshAcc.xf(sac + Vector3(0, 0, 0.14), Vector3(0, 0, 0)), c.get("cl", BLACK), P.SAC, 0.0, spv)
	# back-swept horns
	var hd: Vector3 = c.head
	var hpv := Vector2(tt.y, tt.z)
	for sx: float in [-1.0, 1.0]:
		a.add(MeshAcc.cone(0.022, 1.0, 4), MeshAcc.limb(hd + Vector3(sx * 0.04, 0.05, -0.02), hd + Vector3(sx * 0.09, 0.2, -0.14)), c.get("cl", BLACK), P.HEAD, 0.0, hpv)


static func _burrower(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var orange := Color(0.91, 0.42, 0.06, 0.5)
	# stacked segments with orange glow between them (no legs)
	var ys := [0.12, 0.38, 0.64]
	var rs := [0.25, 0.23, 0.2]
	for k in ys.size():
		var y: float = ys[k]
		var r: float = rs[k]
		var segi := float(ys.size() - k)
		a.add(MeshAcc.cyl(r, 0.22, r * 0.9, 6 if hi else 4), MeshAcc.xf(Vector3(0, y, 0)), DARK if k % 2 == 0 else BLACK, P.SEG, segi)
		a.add(MeshAcc.box(r * 0.9, 0.18, 0.04), MeshAcc.xf(Vector3(0, y, r * 0.85)), OLIVE, P.SEG, segi)
		a.add(MeshAcc.cyl(r * 0.92, 0.05, -1.0, 8 if hi else 5), MeshAcc.xf(Vector3(0, y + 0.135, 0)), orange, P.SEG, segi)
	# round head with a circular maw ringed by orange teeth
	var tt: Vector3 = c.t_top
	var pv := Vector2(tt.y, tt.z)
	var hd := Vector3(0, 1.38, 0.06)
	a.add(MeshAcc.ball(0.15, 6 if hi else 4, 4 if hi else 3), MeshAcc.xf(hd), DARK, P.HEAD, 0.0, pv)
	a.add(MeshAcc.cyl(0.11, 0.03, -1.0, 12), MeshAcc.xf(hd + Vector3(0, 0, 0.14), Vector3(90, 0, 0)), Color(1.0, 0.62, 0.12, 0.0), P.HEAD, 0.0, pv)
	# the maw is a glowing wheel: dark spokes and hub over the ember light
	for k in (8 if hi else 4):
		var ang := TAU * k / (8.0 if hi else 4.0)
		a.add(MeshAcc.box(0.018, 0.1, 0.02), MeshAcc.xf(hd + Vector3(cos(ang) * 0.05, sin(ang) * 0.05, 0.16), Vector3(0, 0, rad_to_deg(ang) - 90.0)), Color(0.08, 0.04, 0.03), P.HEAD, 0.0, pv)
	a.add(MeshAcc.cyl(0.03, 0.03, -1.0, 8), MeshAcc.xf(hd + Vector3(0, 0, 0.165), Vector3(90, 0, 0)), Color(0.08, 0.04, 0.03), P.HEAD, 0.0, pv)
	for t in (10 if hi else 6):
		var ang := TAU * t / (10.0 if hi else 6.0)
		var p := hd + Vector3(cos(ang) * 0.12, sin(ang) * 0.12, 0.14)
		a.add(MeshAcc.cone(0.022, 1.0, 3), MeshAcc.limb(p, p + Vector3(-cos(ang) * 0.07, -sin(ang) * 0.07, 0.05)), Color(0.91, 0.53, 0.1, 0.5), P.HEAD, 0.0, pv)
	# hexagonal stone mound it breaches from, ember light in the cracks
	a.add(MeshAcc.cyl(0.62, 0.16, 0.5, 6), MeshAcc.xf(Vector3(0, 0.06, 0)), Color("4a3222"), P.MOUND)
	a.add(MeshAcc.cyl(0.5, 0.02, -1.0, 6), MeshAcc.xf(Vector3(0, 0.145, 0)), Color("3a271b"), P.MOUND)
	for k in (6 if hi else 3):
		var ang := TAU * k / 6.0 + 0.5
		a.add(MeshAcc.box(0.34, 0.02, 0.025), MeshAcc.xf(Vector3(cos(ang) * 0.36, 0.155, sin(ang) * 0.36), Vector3(0, -rad_to_deg(ang), 0)), Color(1.0, 0.5, 0.1, 0.2), P.MOUND)
		a.add(MeshAcc.box(0.1, 0.03, 0.02), MeshAcc.xf(Vector3(cos(ang + 0.52) * 0.58, 0.1, sin(ang + 0.52) * 0.58), Vector3(0, -rad_to_deg(ang + 0.52) + 90.0, 0)), Color(1.0, 0.55, 0.12, 0.1), P.MOUND)
	if hi:
		for k in 5:
			var ang := TAU * k / 5.0 + 0.4
			_rock(a, Vector3(cos(ang) * 0.52, 0.05, sin(ang) * 0.52), 0.09, DIRT_D, P.MOUND, 0.0, Vector2.ZERO, hi, 50 + k)


static func _mother(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var mag := Color(0.83, 0.17, 0.71, 0.3)
	# faceted egg sac carried on the back, magenta glowing spots
	var sp := Vector3(0, 1.75, -0.45)
	var pv := Vector2(sp.y, sp.z)
	var start := a.v.size()
	a.add(MeshAcc.ball(1.0, 6 if hi else 4, 4 if hi else 3), MeshAcc.xf(sp, Vector3(10, 0, 0), Vector3(0.55, 0.75, 0.5)), Color(0.33, 0.14, 0.43, 0.9), P.SAC, 0.0, pv)
	a.jitter(start, 0.1, 71)
	start = a.v.size()
	a.add(MeshAcc.ball(1.0, 5, 3), MeshAcc.xf(sp + Vector3(0.12, 0.25, -0.05), Vector3.ZERO, Vector3(0.35, 0.4, 0.38)), Color(0.6, 0.3, 0.8, 0.7), P.SAC, 0.0, pv)
	a.jitter(start, 0.06, 73)
	# bone spikes bristling out of the crystal sac
	if hi:
		var dirs := [Vector3(0.0, 1.0, -0.3), Vector3(0.5, 0.8, -0.4), Vector3(-0.5, 0.8, -0.4), Vector3(0.7, 0.2, -0.6), Vector3(-0.7, 0.2, -0.6), Vector3(0.2, 0.5, -0.9), Vector3(-0.25, 0.6, -0.85)]
		for k in dirs.size():
			var d: Vector3 = (dirs[k] as Vector3).normalized()
			var base := sp + Vector3(d.x * 0.5, d.y * 0.68, d.z * 0.46)
			a.add(MeshAcc.cone(0.035, 1.0, 4), MeshAcc.limb(base, base + d * (0.28 + 0.06 * (k % 3))), BONE, P.SAC, 0.0, pv)
	var spots := [Vector3(0.3, 0.2, -0.3), Vector3(-0.32, 0.0, -0.28), Vector3(0.15, -0.3, -0.38), Vector3(-0.1, 0.42, -0.25), Vector3(0.4, -0.15, -0.05), Vector3(-0.42, 0.3, 0.0)]
	for k in (spots.size() if hi else 3):
		a.add(MeshAcc.ball(0.06, 4, 2), MeshAcc.xf(sp + spots[k]), mag, P.SAC, float(k), pv)
	# young clinging to the sac: small dark runts, head up; the shader shows
	# only as many as she still carries
	for k in (YOUNG_N if hi else 4):
		var ang := -1.2 + 2.4 * float(k) / float(YOUNG_N - 1 if hi else 3)
		var lat := 0.35 if k % 2 == 0 else -0.25
		var yp := sp + Vector3(0.55 * sin(ang) * cos(lat), 0.75 * sin(lat), -0.5 * cos(ang) * cos(lat)) * 1.05
		var ypv := Vector2(yp.y, yp.z)
		var yo := float(k)
		a.add(MeshAcc.ball(1.0, 4, 3), MeshAcc.xf(yp, Vector3(20, 0, 0), Vector3(0.07, 0.1, 0.06)), DARK, P.YOUNG, yo, ypv)
		a.add(MeshAcc.ball(0.045, 4, 2), MeshAcc.xf(yp + Vector3(0, 0.1, -0.03)), BLACK, P.YOUNG, yo, ypv)
		if hi:
			for sx: float in [-1.0, 1.0]:
				a.add(MeshAcc.cone(0.012, 1.0, 3), MeshAcc.limb(yp + Vector3(sx * 0.04, 0.02, 0.0), yp + Vector3(sx * 0.1, -0.06, 0.04)), BLACK, P.YOUNG, yo, ypv)
			a.add(MeshAcc.ball(0.012, 3, 2), MeshAcc.xf(yp + Vector3(0.015, 0.11, -0.07)), Color(0.83, 0.17, 0.71, 0.2), P.YOUNG, yo, ypv)
	# crown of white spikes
	var hd: Vector3 = c.head
	var hpv := Vector2(c.t_top.y, c.t_top.z)
	for k in (7 if hi else 4):
		var ang := -60.0 + k * (120.0 / (6.0 if hi else 3.0))
		var base := hd + Vector3(sin(deg_to_rad(ang)) * 0.08, 0.08, -0.02 + cos(deg_to_rad(ang)) * 0.02)
		var tip := base + Vector3(sin(deg_to_rad(ang)) * 0.16, 0.36 + 0.08 * cos(deg_to_rad(ang * 2.0)), -0.08)
		a.add(MeshAcc.cone(0.025, 1.0, 3), MeshAcc.limb(base, tip), BONE, P.HEAD, 0.0, hpv)
