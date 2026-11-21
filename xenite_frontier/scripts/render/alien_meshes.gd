class_name AlienMeshes
extends RefCounted
## The swarm: one family of predatory grey aliens - bald, big-craniumed,
## huge almond eyes, slit mouths full of teeth, long clawed limbs. They walk
## upright and drop to all fours to sprint (see alien.gdshader). Each strain
## keeps a distinct silhouette, posture and glowing eye/marking colour:
##   Stalker   lean grey sprinter, amber eyes, spine ridge
##   Mauler    hulking slate brute, red armour plates, huge fists, knuckle-walks
##   Spitter   thin green-grey biped, glowing acid throat and back sacs
##   Snatcher  very tall pale-violet grey, enormous arms with hooked fingers
##   Burrower  low armoured crawler, orange shovel claws, always on all fours
##   Brood Mother  towering matriarch, bone crown, bloated abdomen of glowing eggs
## Each mesh is built twice: lod 0 (near) and lod 1 (zoomed out).

const GLOW := 0.0  # vertex alpha for emissive parts

enum P { TORSO, HEAD, UARM_L, UARM_R, FARM_L, FARM_R, THIGH_L, THIGH_R, SHIN_L, SHIN_R, STATIC, TAIL }


static func _cfg(id: String) -> Dictionary:
	match id:
		"stalker":
			return {"hy": 0.62, "ky": 0.33, "sy": 1.02, "sx": 0.15, "hx": 0.08, "head_r": 0.2, "head_y": 1.24, "head_z": 0.03,
				"arm_len": 0.84, "arm_t": 0.05, "fore_t": 0.045, "leg_t": 0.065, "shin_t": 0.05, "chest": Vector3(0.14, 0.22, 0.1),
				"skin": Color(0.4, 0.42, 0.45), "eye": Color(1.0, 0.62, 0.1, GLOW), "claw": Color(0.86, 0.82, 0.74),
				"q_min": 0.0, "q_max": 1.0, "run_lo": 0.45, "run_hi": 0.75, "gait": 11.0, "leg_amp": 0.6, "arm_amp": 0.5}
		"mauler":
			return {"hy": 0.8, "ky": 0.42, "sy": 1.5, "sx": 0.36, "hx": 0.16, "head_r": 0.15, "head_y": 1.52, "head_z": 0.24,
				"arm_len": 1.22, "arm_t": 0.11, "fore_t": 0.15, "leg_t": 0.12, "shin_t": 0.1, "chest": Vector3(0.4, 0.42, 0.3),
				"skin": Color(0.26, 0.27, 0.3), "mark": Color(0.5, 0.07, 0.05), "eye": Color(1.0, 0.15, 0.08, GLOW), "claw": Color(0.8, 0.76, 0.7),
				"q_min": 0.45, "q_max": 0.8, "run_lo": 0.3, "run_hi": 0.8, "gait": 6.0, "leg_amp": 0.4, "arm_amp": 0.45}
		"spitter":
			return {"hy": 0.68, "ky": 0.36, "sy": 1.12, "sx": 0.13, "hx": 0.08, "head_r": 0.18, "head_y": 1.34, "head_z": 0.02,
				"arm_len": 0.6, "arm_t": 0.045, "fore_t": 0.04, "leg_t": 0.06, "shin_t": 0.05, "chest": Vector3(0.12, 0.24, 0.09),
				"skin": Color(0.36, 0.41, 0.36), "sac": Color(0.45, 1.0, 0.2, GLOW), "eye": Color(0.5, 1.0, 0.25, GLOW), "claw": Color(0.8, 0.85, 0.7),
				"q_min": 0.0, "q_max": 0.15, "run_lo": 0.6, "run_hi": 0.9, "gait": 8.0, "leg_amp": 0.5, "arm_amp": 0.35}
		"snatcher":
			return {"hy": 1.0, "ky": 0.52, "sy": 1.6, "sx": 0.17, "hx": 0.08, "head_r": 0.19, "head_y": 1.84, "head_z": 0.04,
				"arm_len": 1.45, "arm_t": 0.045, "fore_t": 0.04, "leg_t": 0.06, "shin_t": 0.048, "chest": Vector3(0.14, 0.3, 0.1),
				"skin": Color(0.5, 0.47, 0.56), "eye": Color(0.72, 0.35, 1.0, GLOW), "claw": Color(0.95, 0.92, 1.0),
				"q_min": 0.0, "q_max": 1.0, "run_lo": 0.5, "run_hi": 0.8, "gait": 9.0, "leg_amp": 0.55, "arm_amp": 0.45, "fingers": 0.32}
		"burrower":
			return {"hy": 0.5, "ky": 0.27, "sy": 0.95, "sx": 0.2, "hx": 0.13, "head_r": 0.14, "head_y": 1.04, "head_z": 0.1,
				"arm_len": 0.62, "arm_t": 0.07, "fore_t": 0.075, "leg_t": 0.08, "shin_t": 0.065, "chest": Vector3(0.24, 0.25, 0.18),
				"skin": Color(0.38, 0.33, 0.29), "mark": Color(0.42, 0.28, 0.18), "eye": Color(1.0, 0.55, 0.1, GLOW), "claw": Color(0.95, 0.55, 0.15),
				"q_min": 1.0, "q_max": 1.0, "run_lo": 0.4, "run_hi": 0.8, "gait": 10.0, "leg_amp": 0.45, "arm_amp": 0.5, "shovel": true}
		"brood_mother":
			return {"hy": 1.2, "ky": 0.62, "sy": 2.1, "sx": 0.45, "hx": 0.25, "head_r": 0.3, "head_y": 2.42, "head_z": 0.18,
				"arm_len": 1.7, "arm_t": 0.14, "fore_t": 0.15, "leg_t": 0.18, "shin_t": 0.15, "chest": Vector3(0.5, 0.5, 0.42),
				"skin": Color(0.5, 0.47, 0.5), "eggs": Color(1.0, 0.3, 0.7, GLOW), "eye": Color(1.0, 0.25, 0.6, GLOW), "claw": Color(0.92, 0.88, 0.78),
				"q_min": 0.3, "q_max": 0.55, "run_lo": 0.3, "run_hi": 0.9, "gait": 3.5, "leg_amp": 0.35, "arm_amp": 0.3}
	return _cfg("stalker")


## Shader uniforms for a strain (joint pivots + gait).
static func rig(id: String) -> Dictionary:
	var c := _cfg(id)
	var hy: float = c.hy
	var sy: float = c.sy
	var arm_len: float = c.arm_len
	# pitch so the hands reach the ground on all fours; crouch the rest
	var cos_p := clampf((arm_len + 0.05 - hy) / (sy - hy), 0.2, 1.0)
	var pitch := acos(cos_p)
	var hand_h := hy + (sy - hy) * cos_p - arm_len
	return {
		"hip": Vector2(c.hx, hy), "knee_y": c.ky, "shoulder": Vector3(c.sx, sy, 0.0),
		"elbow_y": sy - arm_len * 0.5, "neck_y": sy + 0.04, "pitch_max": pitch,
		"q_min": c.q_min, "q_max": c.q_max, "run_lo": c.run_lo, "run_hi": c.run_hi,
		"quad_drop": maxf(0.0, hand_h - 0.05) * 0.6, "gait_freq": c.gait,
		"leg_amp": c.leg_amp, "arm_amp": c.arm_amp, "knee_amp": 0.7,
	}


static func build(id: String, lod := 0) -> ArrayMesh:
	var a := MeshAcc.new()
	var c := _cfg(id)
	var hi := lod == 0
	_biped(a, c, hi)
	match id:
		"stalker": _stalker(a, c, hi)
		"mauler": _mauler(a, c, hi)
		"spitter": _spitter(a, c, hi)
		"snatcher": pass
		"burrower": _burrower(a, c, hi)
		"brood_mother": _mother(a, c, hi)
	return a.commit(false)


static func _biped(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var seg := 9 if hi else 5
	var rings := 5 if hi else 3
	var cseg := 7 if hi else 4
	var skin: Color = c.skin
	var claw: Color = c.claw
	var hy: float = c.hy
	var ky: float = c.ky
	var sy: float = c.sy
	var sx: float = c.sx
	var hx: float = c.hx
	var hr: float = c.head_r
	var head_y: float = c.head_y
	var head_z: float = c.head_z
	var chest: Vector3 = c.chest
	var dark := skin.darkened(0.55)

	# pelvis + torso (ribcage tapering to a thin waist)
	a.add(MeshAcc.ball(1.0, seg, rings), MeshAcc.xf(Vector3(0, hy, 0), Vector3.ZERO, Vector3(hx + 0.07, 0.11, chest.z * 0.9)), skin, P.TORSO)
	a.add(MeshAcc.ball(1.0, seg, rings), MeshAcc.xf(Vector3(0, hy + (sy - hy) * 0.62, -0.01), Vector3.ZERO, Vector3(chest.x, (sy - hy) * 0.55, chest.z)), skin, P.TORSO)
	a.add(MeshAcc.capsule(chest.x * 0.45, (sy - hy) * 0.7, cseg, 1), MeshAcc.xf(Vector3(0, hy + (sy - hy) * 0.3, 0)), skin.darkened(0.08), P.TORSO)
	# neck + head (big bald cranium, small jaw, huge almond eyes)
	a.add(MeshAcc.capsule(hr * 0.24, 1.0, cseg, 1), MeshAcc.limb(Vector3(0, sy - 0.02, 0), Vector3(0, head_y - hr * 0.6, head_z * 0.6)), skin, P.HEAD)
	a.add(MeshAcc.ball(hr, seg, rings), MeshAcc.xf(Vector3(0, head_y + hr * 0.18, head_z - hr * 0.12), Vector3.ZERO, Vector3(1.0, 1.08, 1.18)), skin, P.HEAD)
	a.add(MeshAcc.ball(hr * 0.62, seg, rings), MeshAcc.xf(Vector3(0, head_y - hr * 0.52, head_z + hr * 0.38), Vector3.ZERO, Vector3(0.85, 0.9, 1.0)), skin, P.HEAD)
	for side: float in [-1.0, 1.0]:
		a.add(MeshAcc.ball(hr * 0.34, seg if hi else 5, 3), MeshAcc.xf(Vector3(side * hr * 0.43, head_y - hr * 0.02, head_z + hr * 0.78), Vector3(-8, side * 18.0, side * -24.0), Vector3(1.0, 0.52, 0.42)), c.eye, P.HEAD)
	a.add(MeshAcc.box(hr * 0.75, hr * 0.09, hr * 0.25), MeshAcc.xf(Vector3(0, head_y - hr * 0.74, head_z + hr * 0.86)), Color(0.08, 0.04, 0.04), P.HEAD)
	if hi:
		for k in 4:
			var tx := (-1.5 + k) * hr * 0.17
			a.add(MeshAcc.cone(hr * 0.05, hr * 0.2, 4), MeshAcc.xf(Vector3(tx, head_y - hr * 0.73, head_z + hr * 0.95), Vector3(180, 0, 0)), claw, P.HEAD)

	# arms: shoulder -> elbow -> wrist, three long claws
	var arm_len: float = c.arm_len
	var ey := sy - arm_len * 0.5
	for side: float in [-1.0, 1.0]:
		var l := side < 0.0
		var sh := Vector3(side * sx, sy, 0.0)
		var el := Vector3(side * sx * 1.04, ey, 0.02)
		var wr := Vector3(side * sx * 1.07, sy - arm_len + 0.06, 0.04)
		a.add(MeshAcc.ball(c.arm_t * 1.25, cseg, 3), MeshAcc.xf(sh), skin, P.UARM_L if l else P.UARM_R)
		a.add(MeshAcc.capsule(c.arm_t, 1.0, cseg, 1), MeshAcc.limb(sh, el), skin, P.UARM_L if l else P.UARM_R)
		a.add(MeshAcc.ball(c.arm_t * 1.1, cseg, 3), MeshAcc.xf(el), skin, P.FARM_L if l else P.FARM_R)
		a.add(MeshAcc.capsule(c.fore_t, 1.0, cseg, 1), MeshAcc.limb(el, wr), skin, P.FARM_L if l else P.FARM_R)
		var flen: float = c.get("fingers", 0.16)
		for f in (3 if hi else 2):
			var fx: float = (f - 1.0) * c.fore_t * 0.9
			var tip := wr + Vector3(fx * side, -flen, 0.05 + flen * 0.35)
			a.add(MeshAcc.cone(c.fore_t * 0.42, 1.0, 4), MeshAcc.limb(wr + Vector3(fx * side, 0, 0), tip, Vector3(1, 1, 1)), claw if f != 1 else skin, P.FARM_L if l else P.FARM_R)

	# legs: hip -> knee -> ankle, long foot with toe claws
	for side: float in [-1.0, 1.0]:
		var l := side < 0.0
		var hp := Vector3(side * hx, hy, 0.0)
		var kn := Vector3(side * hx * 1.05, ky, 0.05)
		var an := Vector3(side * hx * 1.05, 0.07, -0.03)
		a.add(MeshAcc.capsule(c.leg_t, 1.0, cseg, 1), MeshAcc.limb(hp, kn), skin, P.THIGH_L if l else P.THIGH_R)
		a.add(MeshAcc.ball(c.leg_t * 1.05, cseg, 3), MeshAcc.xf(kn), skin, P.SHIN_L if l else P.SHIN_R)
		a.add(MeshAcc.capsule(c.shin_t, 1.0, cseg, 1), MeshAcc.limb(kn, an), skin, P.SHIN_L if l else P.SHIN_R)
		a.add(MeshAcc.ball(1.0, cseg, 3), MeshAcc.xf(an + Vector3(0, -0.02, 0.07), Vector3.ZERO, Vector3(c.shin_t * 1.3, 0.04, 0.12)), dark, P.SHIN_L if l else P.SHIN_R)
		if hi:
			a.add(MeshAcc.cone(c.shin_t * 0.5, 0.1, 4), MeshAcc.xf(an + Vector3(0, -0.03, 0.2), Vector3(90, 0, 0)), claw, P.SHIN_L if l else P.SHIN_R)


static func _stalker(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	# serrated spine ridge
	for k in (5 if hi else 3):
		var t := float(k) / 4.0
		var y := lerpf(c.sy - 0.05, c.hy + 0.05, t)
		a.add(MeshAcc.cone(0.03, 0.13, 4), MeshAcc.xf(Vector3(0, y, -c.chest.z - 0.02), Vector3(-60, 0, 0)), c.skin.darkened(0.4), P.TORSO)


static func _mauler(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var mark: Color = c.mark
	# shoulder armour, back plates, huge fists
	for side: float in [-1.0, 1.0]:
		a.add(MeshAcc.ball(1.0, 6, 3), MeshAcc.xf(Vector3(side * c.sx * 0.95, c.sy + 0.04, -0.02), Vector3(0, 0, side * 20.0), Vector3(0.22, 0.12, 0.24)), mark, P.UARM_L if side < 0 else P.UARM_R)
		a.add(MeshAcc.ball(0.17, 7 if hi else 5, 4), MeshAcc.xf(Vector3(side * c.sx * 1.07, c.sy - c.arm_len + 0.02, 0.05)), c.skin.darkened(0.15), P.FARM_L if side < 0 else P.FARM_R)
	for k in (3 if hi else 2):
		var y := lerpf(c.sy - 0.1, c.hy + 0.25, float(k) / 2.0)
		a.add(MeshAcc.box(0.32 - k * 0.05, 0.08, 0.16), MeshAcc.xf(Vector3(0, y, -c.chest.z * 0.9), Vector3(-20, 0, 0)), mark, P.TORSO)


static func _spitter(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var sac: Color = c.sac
	a.add(MeshAcc.ball(0.24, 8 if hi else 5, 4), MeshAcc.xf(Vector3(0, c.sy - 0.12, -0.2), Vector3.ZERO, Vector3(1.0, 1.15, 0.9)), sac, P.TORSO)
	a.add(MeshAcc.ball(0.1, 7 if hi else 5, 4), MeshAcc.xf(Vector3(0, c.head_y - c.head_r * 0.95, c.head_z + 0.06)), sac, P.HEAD)


static func _burrower(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var mark: Color = c.mark
	# armoured back plates and big shovel claws
	for k in (4 if hi else 2):
		var y := lerpf(c.sy - 0.05, c.hy, float(k) / 3.0)
		a.add(MeshAcc.ball(1.0, 6, 3), MeshAcc.xf(Vector3(0, y, -c.chest.z * 0.75), Vector3(-15, 0, 0), Vector3(0.2, 0.06, 0.12)), mark, P.TORSO)
	for side: float in [-1.0, 1.0]:
		var wr := Vector3(side * c.sx * 1.07, c.sy - c.arm_len + 0.06, 0.04)
		a.add(MeshAcc.box(0.16, 0.04, 0.2), MeshAcc.xf(wr + Vector3(0, -0.06, 0.1), Vector3(30, 0, 0)), c.claw, P.FARM_L if side < 0 else P.FARM_R)


static func _mother(a: MeshAcc, c: Dictionary, hi: bool) -> void:
	var eggs: Color = c.eggs
	# bloated abdomen trailing behind, studded with glowing egg sacs
	a.add(MeshAcc.ball(1.0, 10 if hi else 6, 6 if hi else 4), MeshAcc.xf(Vector3(0, 1.25, -1.25), Vector3(-10, 0, 0), Vector3(0.9, 0.78, 1.3)), c.skin.lerp(Color(0.42, 0.38, 0.46), 0.5), P.TAIL)
	var spots := [Vector3(0.5, 1.6, -1.0), Vector3(-0.55, 1.5, -1.4), Vector3(0.2, 1.95, -1.6), Vector3(-0.3, 1.0, -2.1), Vector3(0.6, 1.05, -1.9), Vector3(0.0, 1.7, -0.55)]
	for k in (spots.size() if hi else 3):
		a.add(MeshAcc.ball(0.2, 6, 3), MeshAcc.xf(spots[k]), eggs, P.TAIL)
	# bone crown
	for k in (6 if hi else 3):
		var ang := -60.0 + k * 24.0
		var p := Vector3(sin(deg_to_rad(ang)) * c.head_r * 0.8, c.head_y + c.head_r * 0.9, c.head_z - c.head_r * 0.3 + cos(deg_to_rad(ang)) * c.head_r * 0.2)
		a.add(MeshAcc.cone(0.06, 0.45, 4), MeshAcc.xf(p, Vector3(-30, 0, -ang * 0.6)), c.claw, P.HEAD)
