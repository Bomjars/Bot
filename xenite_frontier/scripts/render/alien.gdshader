shader_type spatial;
// Swarm material (concept "predatory/primal - humanoid lineup v3"): faceted
// charcoal bodies with an olive front panel and glowing identity markings,
// animated entirely on the GPU as a biped joint rig.
//
// Per vertex: UV.x part, UV.y phase offset (left/right, segment index),
//             UV2 = this part's own joint pivot (y, z) in model space.
// Parts: 0 body  1 head  2 thigh  3 upper arm  4 segment  5 sac
//        7 static  8 plates/rocks  9 shin  10 forearm  11 dirt mound
// INSTANCE_CUSTOM: r hit flash | g 1 dead / 2 charred | b stride phase
//   (advanced on the CPU by distance walked: feet never slide) |
//   a state: >= 0 speed ratio, -1 feeding/sniffing, -2 attacking,
//   -3 burrowing (only the head and a dirt mound break the surface)
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

varying vec4 vcol;
varying vec3 fx;

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

void vertex() {
	int pid = int(UV.x + 0.5);
	float off = UV.y;
	vec2 pv = UV2;
	float dead = min(INSTANCE_CUSTOM.g, 1.0);
	float alive = 1.0 - dead;
	float st = INSTANCE_CUSTOM.a;
	float burrow = step(st, -2.5) * alive;
	float attacking = step(st, -1.5) * (1.0 - burrow) * alive;
	float feeding = step(st, -0.5) * step(-1.5, st) * alive;
	float spd = max(st, 0.0);
	float move = smoothstep(0.04, 0.25, spd) * alive;
	float ph = INSTANCE_CUSTOM.b;
	float gs = sin(ph + off);
	float gc = cos(ph + off);
	float slash = sin(TIME * 12.0 + off);
	float q = mix(q_min, q_max, smoothstep(run_lo, run_hi, spd));
	q = mix(q, max(q, 0.85), feeding);
	q = mix(q, attack_q, attacking);
	q *= alive;
	float P = q * pitch_max;
	vec3 v = VERTEX;
	vec3 n = NORMAL;

	// legs: knee bend, then hip swing (bigger strides at a gallop)
	float swing = -gs * leg_amp * move * (1.0 + 0.5 * q) - feeding * 0.4 + dead * dead_curl * 0.7;
	if (pid == 9) {
		float bend = max(0.0, gc) * knee_amp * move + q * 0.5 + feeding * 0.6 + dead * dead_curl;
		v = rot_x(v, pv.x, pv.y, bend);
		n = rot_xn(n, bend);
		v = rot_x(v, hip_y, hip_z, swing);
		n = rot_xn(n, swing);
	} else if (pid == 2) {
		v = rot_x(v, pv.x, pv.y, swing);
		n = rot_xn(n, swing);
	}
	// arms: elbow, then shoulder (reach for the ground on all fours, slash when attacking)
	float arm = -P + gs * arm_amp * move * (1.0 + 0.4 * q) - feeding * 0.35
		+ attacking * (-1.7 + 0.9 * slash) + dead * dead_arm;
	if (pid == 10) {
		float elbow = -(0.2 + 0.4 * max(0.0, -gs)) * move - 0.12 - attacking * (0.6 + 0.4 * slash);
		v = rot_x(v, pv.x, pv.y, elbow);
		n = rot_xn(n, elbow);
		v = rot_x(v, sh_y, sh_z, arm);
		n = rot_xn(n, arm);
	} else if (pid == 3) {
		v = rot_x(v, pv.x, pv.y, arm);
		n = rot_xn(n, arm);
	} else if (pid == 1) {
		float head = -P * 0.75 + feeding * (0.45 + 0.3 * sin(TIME * 9.0 + off)) + attacking * 0.3 * slash + sin(ph * 2.0) * 0.04 * move;
		v = rot_x(v, pv.x, pv.y, head);
		n = rot_xn(n, head);
	} else if (pid == 5) {
		vec3 c = vec3(0.0, pv.x, pv.y);
		float k = (1.0 + 0.08 * sin(TIME * 3.0 + off) * alive) * mix(1.0, 0.35, dead);
		v = c + (v - c) * k;
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
	if (pid == 0 || pid == 1 || pid == 3 || pid == 10 || pid == 5 || pid == 8 || pid == 4) {
		v = rot_x(v, hip_y, hip_z, P);
		n = rot_xn(n, P);
	}
	if (pid == 0 || pid == 5) {
		v *= 1.0 + sin(TIME * 2.5 + off) * 0.012 * alive;
	}
	v.y -= q * quad_drop;
	// burrowing: everything but the dirt mound sinks below the surface
	if (pid == 11) {
		// the mound belongs to the living burrower only
		v.xz *= (1.0 + burrow * 0.6) * alive;
		v.y -= (1.0 - burrow) * 0.02 + dead * 2.0;
	} else {
		v.y -= burrow * sink;
	}
	VERTEX = v;
	NORMAL = normalize(n);
	// vertex colours are authored in sRGB: convert to linear for ALBEDO
	vcol = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
	fx = vec3(INSTANCE_CUSTOM.r, dead, step(1.5, INSTANCE_CUSTOM.g));
}

void fragment() {
	vec3 base = vcol.rgb;
	float dead = fx.g;
	float charred = fx.b;
	base = mix(base, base * 0.6, dead);
	base = mix(base, vec3(0.03, 0.025, 0.02), charred);
	ALBEDO = mix(base, vec3(1.0), fx.r);
	ROUGHNESS = mix(0.55, 0.85, dead);
	SPECULAR = sheen;
	float glow = (1.0 - vcol.a) * (1.0 - dead * 0.85);
	EMISSION = vcol.rgb * glow * 1.8 + vec3(1.0, 0.9, 0.8) * fx.r * 0.8 + vec3(1.0, 0.35, 0.05) * charred * 0.15;
	RIM = 0.3 * (1.0 - dead);
	RIM_TINT = 0.6;
}
