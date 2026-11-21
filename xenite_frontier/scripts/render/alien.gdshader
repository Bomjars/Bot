shader_type spatial;
// Swarm material: dark oily chitin with glowing identity markings, animated
// entirely on the GPU. Every vertex carries:
//   UV.x  part type   UV.y  phase offset (gait group / segment index)
//   UV2   joint pivot (y, z) in model space
// Part types: 0 body  1 head  2 leg  3 arm/forelimb  4 worm segment
//             5 sac   6 tail/spine  7 static  8 shell plate
// INSTANCE_CUSTOM: r = hit flash, g = 1 dead / 2 charred corpse,
//                  b = stride phase (advanced on the CPU by distance walked,
//                      so feet never slide), a = state: >= 0 speed ratio,
//                      -1 feeding / sniffing (head down), -2 attacking.

uniform float leg_amp = 0.5;
uniform float arm_amp = 0.45;
uniform float wave_amp = 0.12;
uniform float leg_lift = 0.06;
uniform float dead_curl = 1.0;     // legs fold in on death
uniform float dead_arm = 0.0;      // arm pose on death
uniform float seg_gap = 0.0;       // worm segments drift apart on death
uniform float split = 0.0;         // body splits open along the back on death
uniform float split_y = 10.0;
uniform float sheen = 0.55;

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
	float feeding = step(st, -0.5) * step(-1.5, st) * alive;
	float attacking = step(st, -1.5) * alive;
	float spd = max(st, 0.0);
	float move = smoothstep(0.04, 0.25, spd) * alive;
	float ph = INSTANCE_CUSTOM.b;
	float slash = sin(TIME * 12.0 + off);
	vec3 v = VERTEX;
	vec3 n = NORMAL;

	if (pid == 2) {
		// legs: swing about the hip, lift on the forward stroke, fold in death
		float a = sin(ph + off) * leg_amp * move + dead * dead_curl;
		v = rot_x(v, pv.x, pv.y, a);
		n = rot_xn(n, a);
		v.y += max(0.0, cos(ph + off)) * leg_lift * move * step(v.y, pv.x);
	} else if (pid == 3) {
		float a = sin(ph + off) * arm_amp * move - feeding * 0.5
			+ attacking * (-1.4 + 0.8 * slash) + dead * dead_arm;
		v = rot_x(v, pv.x, pv.y, a);
		n = rot_xn(n, a);
	} else if (pid == 1) {
		// head: nod while moving, dip to feed / sniff, lunge when attacking
		float a = sin(ph * 2.0) * 0.05 * move + feeding * (0.45 + 0.3 * sin(TIME * 9.0 + off)) + attacking * 0.35 * slash;
		v = rot_x(v, pv.x, pv.y, a);
		n = rot_xn(n, a);
	} else if (pid == 4) {
		// worm segments: travelling wave; drift apart into a line when dead
		v.x += sin(ph - off) * wave_amp * (0.35 + move) * alive;
		v.y += cos(ph - off) * 0.03 * move;
		v.z -= off * seg_gap * dead;
	} else if (pid == 5) {
		// sacs pulse; burst flat on death
		vec3 c = vec3(0.0, pv.x, pv.y);
		float k = (1.0 + 0.07 * sin(TIME * 3.0 + off) * alive) * mix(1.0, 0.3, dead);
		v = c + (v - c) * k;
	} else if (pid == 6) {
		v.x += sin(ph * 0.5 + v.z * 2.0) * 0.06 * (move + 0.3) * alive;
	} else if (pid == 8) {
		// shell plates crack open on death
		v += n * 0.12 * dead;
	}
	if (pid == 0 && v.y > split_y) {
		v.x += sign(v.x) * split * dead;
	}
	if (pid == 0 || pid == 5) {
		v *= 1.0 + sin(TIME * 2.5 + off) * 0.012 * alive;
	}
	v.y -= feeding * 0.05;
	v.z += attacking * 0.06 * slash;
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
	// oily chitin: glossy, purple rim
	ROUGHNESS = mix(0.28, 0.8, dead);
	SPECULAR = sheen;
	METALLIC = 0.1;
	float glow = (1.0 - vcol.a) * (1.0 - dead * 0.85);
	EMISSION = vcol.rgb * glow * 1.7 + vec3(1.0, 0.9, 0.8) * fx.r * 0.8 + vec3(1.0, 0.35, 0.05) * charred * 0.15;
	RIM = 0.45 * (1.0 - dead);
	RIM_TINT = 0.85;
}
