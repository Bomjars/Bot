shader_type spatial;
// Swarm material (concept "predatory/primal - humanoid lineup v3"): faceted
// charcoal bodies with an olive front panel and glowing identity markings,
// animated entirely on the GPU as a biped joint rig.
//
// Per vertex: UV.x part, UV.y phase offset (left/right, segment index),
//             UV2 = this part's own joint pivot (y, z) in model space.
// Parts: 0 body  1 head  2 thigh  3 upper arm  4 segment  5 sac
//        7 static  8 plates/rocks  9 shin  10 forearm  11 dirt mound
//        12 young clinging to the Brood Mother (UV.y = index)
// INSTANCE_CUSTOM: r hit flash | g dead: 1 / charred: 2, alive: -(extra +
//   2 if enraged) where extra = Spitter sac drained / Brood young carried |
//   b stride phase (advanced on the CPU by distance walked: feet never slide) |
//   a state: >= 0 speed ratio, -1 feeding/sniffing, -2 attacking,
//   -3 burrowing (only the head and a dirt mound break the surface),
//   -4..-5 tell (progress 0..1), -6..-7 action (drag / charge), -8 stunned.
// Lineup v4 tells: 1 Spitter inflates its sac, 2 Burrower cracks the ground
// (amber glow), 3 Mauler winds up a charge, 4 Elder roars.
// Posture q: 0 upright .. 1 hunched / on all fours; strains blend between
// q_min and q_max with speed, so the fast ones drop to all fours to sprint.

uniform float hip_y = 0.72;
uniform float hip_z = 0.0;
uniform float sh_y = 1.0;
uniform float sh_z = 0.15;
uniform float pitch_max = 0.9;
uniform float q_min = 0.0;
uniform float q_max = 0.8;
uniform float run_lo = 0.5;
uniform float run_hi = 0.85;
uniform float attack_q = 0.3;
uniform float quad_drop = 0.0;
uniform float leg_amp = 0.55;
uniform float knee_amp = 0.8;
uniform float arm_amp = 0.5;
uniform float sink = 0.0;
uniform float dead_curl = 1.0;
uniform float dead_arm = 0.0;
uniform float seg_gap = 0.0;
uniform float split = 0.0;
uniform float split_y = 10.0;
uniform float sheen = 0.4;
uniform int tell_kind = 0;
uniform int act_kind = 0;
uniform float twitch = 0.0;
uniform float sac_drain = 0.0;
uniform float young_n = 0.0;
uniform vec3 rim_col : source_color = vec3(0.85, 0.82, 0.74);

varying vec4 vcol;
varying vec3 fx;
varying vec2 vfx;   // x amber breach glow, y enraged
varying vec3 lpos;  // rest-pose model position: mottling sticks to the body
varying float vmat; // 0 body, 1 dirt mound, 2 boulder plates (both matte)

vec3 rot_x(vec3 v, float py, float pz, float a) {
	float c = cos(a);
	float s = sin(a);
	vec3 p = vec3(v.x, v.y - py, v.z - pz);
	return vec3(p.x, p.y * c - p.z * s + py, p.y * s + p.z * c + pz);
}
vec3 rot_xn(vec3 n, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(n.x, n.y * c - n.z * s, n.y * s + n.z * c);
}
vec3 rot_y(vec3 v, float pz, float a) {
	float c = cos(a);
	float s = sin(a);
	vec3 p = vec3(v.x, v.y, v.z - pz);
	return vec3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c + pz);
}
float hash1(float n) {
	return fract(sin(n * 78.233) * 43758.5453);
}
float h3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float n3(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h3(i), h3(i + vec3(1, 0, 0)), u.x), mix(h3(i + vec3(0, 1, 0)), h3(i + vec3(1, 1, 0)), u.x), u.y),
		mix(mix(h3(i + vec3(0, 0, 1)), h3(i + vec3(1, 0, 1)), u.x), mix(h3(i + vec3(0, 1, 1)), h3(i + vec3(1, 1, 1)), u.x), u.y), u.z);
}

void vertex() {
	int pid = int(UV.x + 0.5);
	float off = UV.y;
	vec2 pv = UV2;
	float g = INSTANCE_CUSTOM.g;
	float dead = clamp(g, 0.0, 1.0);
	float alive = 1.0 - dead;
	float ng = max(-g, 0.0);
	float rage = step(1.5, ng);
	float extra = clamp(ng - 2.0 * rage, 0.0, 1.0);
	float st = INSTANCE_CUSTOM.a;
	float feeding = step(st, -0.5) * step(-1.5, st) * alive;
	float attacking = step(st, -1.5) * step(-2.5, st) * alive;
	float burrow = step(st, -2.5) * step(-3.5, st) * alive;
	float tell = step(st, -3.5) * step(-5.5, st) * alive;
	float tp = clamp(-4.0 - st, 0.0, 1.0) * tell;
	float act = step(st, -5.5) * step(-7.5, st) * alive;
	float stun = step(st, -7.5) * alive;
	float t_sac = tell_kind == 1 ? tp : 0.0;
	float t_breach = tell_kind == 2 ? tell : 0.0;
	float t_wind = tell_kind == 3 ? tp : 0.0;
	float t_roar = tell_kind == 4 ? tp : 0.0;
	float a_drag = act_kind == 1 ? act : 0.0;
	float a_charge = act_kind == 2 ? act : 0.0;
	burrow = max(burrow, t_breach);   // the breach tell happens underground
	float spd = max(st, 0.0) + a_charge + a_drag * 0.55;
	float move = smoothstep(0.04, 0.25, spd) * alive;
	float ph = INSTANCE_CUSTOM.b;
	float gs = sin(ph + off);
	float gc = cos(ph + off);
	float slash = sin(TIME * 12.0 + off);
	float shake = sin(TIME * 31.0 + off);
	float q = mix(q_min, q_max, smoothstep(run_lo, run_hi, spd));
	q = mix(q, max(q, 0.85), feeding);
	q = mix(q, attack_q, attacking);
	q = mix(q, 1.0, a_charge);           // shoulder down, flat out
	q = mix(q, 0.8, t_wind);             // crouched to charge
	q = mix(q, 0.0, max(t_sac, t_roar)); // stands tall
	q = mix(q, 0.45, a_drag);
	q = mix(q, 0.55, stun);
	q *= alive;
	float P = q * pitch_max - t_roar * 0.35 - t_sac * 0.12;
	vec3 v = VERTEX;
	vec3 n = NORMAL;
	lpos = VERTEX;
	vmat = pid == 11 ? 1.0 : (pid == 8 ? 2.0 : 0.0);
	// flinch: knocked back a little when hit
	v.z -= INSTANCE_CUSTOM.r * 0.06 * alive * step(0.5, v.y);

	// legs: knee bend, then hip swing (bigger strides at a gallop)
	float swing = -gs * leg_amp * move * (1.0 + 0.5 * q) - feeding * 0.4 + dead * dead_curl * 0.7 + stun * 0.2;
	if (pid == 9) {
		float bend = max(0.0, gc) * knee_amp * move + q * 0.5 + feeding * 0.6 + dead * dead_curl + t_wind * 0.4;
		v = rot_x(v, pv.x, pv.y, bend);
		n = rot_xn(n, bend);
		v = rot_x(v, hip_y, hip_z, swing);
		n = rot_xn(n, swing);
	} else if (pid == 2) {
		v = rot_x(v, pv.x, pv.y, swing);
		n = rot_xn(n, swing);
	}
	// arms: elbow, then shoulder (reach for the ground on all fours, slash when
	// attacking, fists up to roar, swept back to charge, down to drag)
	float arm = -P + gs * arm_amp * move * (1.0 + 0.4 * q) - feeding * 0.35
		+ attacking * (-1.7 + 0.9 * slash) + dead * dead_arm
		+ t_roar * (-2.7 + 0.12 * shake) + t_wind * 0.9 - a_drag * 0.75 + stun * 0.45;
	if (pid == 10) {
		float elbow = -(0.2 + 0.4 * max(0.0, -gs)) * move - 0.12 - attacking * (0.6 + 0.4 * slash)
			- t_roar * 0.5 + a_drag * 0.25;
		v = rot_x(v, pv.x, pv.y, elbow);
		n = rot_xn(n, elbow);
		v = rot_x(v, sh_y, sh_z, arm);
		n = rot_xn(n, arm);
	} else if (pid == 3) {
		v = rot_x(v, pv.x, pv.y, arm);
		n = rot_xn(n, arm);
	} else if (pid == 1) {
		// stalkers' heads twitch between lunges: sudden small turns
		float tw = twitch * alive * (1.0 - 0.7 * move) * (1.0 - feeding);
		float tick = floor(TIME * 3.2 + float(INSTANCE_ID) * 0.618);
		float yaw = tw * (hash1(tick + float(INSTANCE_ID)) - 0.5) * 1.1;
		float head = -P * 0.75 + feeding * (0.45 + 0.3 * sin(TIME * 9.0 + off)) + attacking * 0.3 * slash
			+ sin(ph * 2.0) * 0.04 * move + tw * (hash1(tick * 1.7 + 3.0) - 0.5) * 0.3
			- t_roar * (0.75 + 0.08 * shake) - t_sac * 0.4 + a_charge * 0.35 + t_wind * 0.45
			+ stun * (0.55 + 0.25 * sin(TIME * 2.3 + off));
		v = rot_y(v, pv.y, yaw);
		n = rot_y(n, 0.0, yaw);
		v = rot_x(v, pv.x, pv.y, head);
		n = rot_xn(n, head);
	} else if (pid == 5) {
		vec3 c = vec3(0.0, pv.x, pv.y);
		float k = (1.0 + 0.08 * sin(TIME * 3.0 + off) * alive) * mix(1.0, 0.35, dead);
		// Spitter: the sac drains with each shot and swells for 1 s before one
		k *= 1.0 - 0.5 * extra * sac_drain;
		k *= 1.0 + t_sac * (0.85 + 0.06 * shake);
		v = c + (v - c) * k;
	} else if (pid == 12) {
		// young: visible while she still carries them; they squirm
		vec3 c = vec3(0.0, pv.x, pv.y);
		float shown = step(off + 0.5, extra * young_n) * alive;
		v = c + (v - c) * shown;
		v.x += sin(TIME * 7.0 + off * 2.3) * 0.012;
	} else if (pid == 8) {
		v += n * 0.14 * dead;
	} else if (pid == 4) {
		v.x += sin(ph + off) * 0.05 * move;
		v.y -= off * seg_gap * dead;
	}
	if (pid == 0 && v.y > split_y) {
		v.x += sign(v.x) * split * dead;
	}
	// upper body pitches forward about the hips
	if (pid == 0 || pid == 1 || pid == 3 || pid == 10 || pid == 5 || pid == 8 || pid == 4 || pid == 12) {
		v = rot_x(v, hip_y, hip_z, P);
		n = rot_xn(n, P);
	}
	if (pid == 0 || pid == 5) {
		v *= 1.0 + sin(TIME * 2.5 + off) * 0.012 * alive;
	}
	// stunned: swaying on its feet; roaring: the whole body shudders
	v.x += (stun * sin(TIME * 3.1) * 0.04 + t_roar * shake * 0.01) * v.y;
	v.y -= q * quad_drop;
	// burrowing: everything but the dirt mound sinks below the surface;
	// the 2 s breach tell heaves the mound and the head starts to rise
	float amber = 0.0;
	if (pid == 11) {
		float heave = t_breach * clamp(-4.0 - st, 0.0, 1.0);
		v.xz *= (1.0 + burrow * 0.6 + heave * 0.25 * (1.0 + 0.25 * shake)) * alive;
		v.y += heave * 0.1 * (1.0 + 0.3 * shake);
		v.y -= (1.0 - burrow) * 0.02 + dead * 2.0;
		// glow leaks from the cracks: flickers, strongest in the darker clods
		amber = heave * (0.55 + 0.45 * sin(TIME * 9.0 + off)) * (1.0 - COLOR.r);
	} else {
		v.y -= burrow * sink * (1.0 - 0.3 * t_breach * clamp(-4.0 - st, 0.0, 1.0));
	}
	VERTEX = v;
	NORMAL = normalize(n);
	// vertex colours are authored in sRGB: convert to linear for ALBEDO
	vcol = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
	fx = vec3(INSTANCE_CUSTOM.r, dead, step(1.5, g));
	vfx = vec2(amber, rage);
}

void fragment() {
	vec3 base = vcol.rgb;
	float dead = fx.g;
	float charred = fx.b;
	float rage = vfx.y;
	float glow = (1.0 - vcol.a) * (1.0 - dead * 0.85);
	float lum = dot(base, vec3(0.3, 0.59, 0.11));
	// what the surface is made of, from its colour: bone (claws, teeth, crown),
	// olive belly panels, or dark chitin
	float bone = smoothstep(0.35, 0.6, lum);
	float olive = smoothstep(0.08, 0.16, lum) * (1.0 - bone) * step(base.b * 1.8, base.g);
	float matte = step(0.5, vmat);
	float chitin = (1.0 - bone) * (1.0 - olive) * (1.0 - step(0.01, glow)) * (1.0 - matte);
	// mottled chitin with darker veins, fixed to the body
	float m = n3(lpos * 9.0);
	float vein = 1.0 - smoothstep(0.0, 0.06, abs(n3(lpos * 4.0 + 7.0) - 0.5));
	base *= mix(1.0, 0.8 + 0.4 * m, chitin + olive * 0.6);
	base *= 1.0 - vein * 0.35 * chitin;
	base = mix(base, base * 0.6, dead);
	base = mix(base, vec3(0.03, 0.025, 0.02), charred);
	base = mix(base, base * vec3(1.6, 0.6, 0.55), rage * 0.35);
	ALBEDO = mix(base, vec3(1.0), fx.r);
	// wet, glossy chitin; matte belly; polished claws
	float rough = mix(0.3 + 0.2 * m, 0.72, olive);
	rough = mix(rough, 0.25, bone);
	rough = mix(rough, 0.9, matte);
	ROUGHNESS = mix(rough, 0.85, max(dead * 0.6, charred));
	SPECULAR = mix(sheen + 0.2, sheen, olive) * (1.0 - charred);
	// enraged: every glowing marking burns red
	vec3 gcol = mix(vcol.rgb, vec3(1.0, 0.08, 0.03), rage);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = gcol * glow * (1.8 + rage * 0.8) + vec3(1.0, 0.9, 0.8) * fx.r * 0.8
		+ vec3(1.0, 0.35, 0.05) * charred * 0.15 + vec3(1.0, 0.42, 0.05) * vfx.x * 0.32
		+ mix(rim_col, vec3(1.0, 0.1, 0.04), rage) * fres * 0.22 * (1.0 - dead) * (1.0 - step(0.5, vmat) * step(vmat, 1.5));
	RIM = 0.35 * (1.0 - dead);
	RIM_TINT = 0.6;
}
