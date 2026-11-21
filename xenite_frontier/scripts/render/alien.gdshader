shader_type spatial;
// Grey alien family: GPU "skeleton" animation. Each vertex carries a part id
// in UV.x; the shader rotates parts about their joints (hip, knee, shoulder,
// elbow, neck) every frame, so 10k animated aliens cost no CPU.
//
// INSTANCE_CUSTOM: r = hit flash, g = 1 dead (corpse) / 2 charred corpse,
//                  b = stride phase (advanced on the CPU by distance walked,
//                      so feet never slide), a = state: >= 0 speed ratio,
//                      -1 feeding (crouch + peck), -2 attacking (rear + slash)
// Posture q: 0 upright biped .. 1 on all fours. Strains blend between their
// q_min and q_max with speed (run_lo..run_hi): they drop to all fours to sprint.
//
// Parts: 0 torso  1 head  2/3 upper arm L/R  4/5 forearm L/R
//        6/7 thigh L/R  8/9 shin L/R  10 static  11 tail/abdomen (sways)

uniform vec2 hip = vec2(0.1, 0.62);        // x half width, y height
uniform float knee_y = 0.32;
uniform vec3 shoulder = vec3(0.16, 1.04, 0.0);
uniform float elbow_y = 0.62;
uniform float neck_y = 1.1;
uniform float pitch_max = 1.0;
uniform float q_min = 0.0;
uniform float q_max = 1.0;
uniform float run_lo = 0.45;
uniform float run_hi = 0.75;
uniform float quad_drop = 0.0;
uniform float gait_freq = 11.0;
uniform float leg_amp = 0.55;
uniform float arm_amp = 0.5;
uniform float knee_amp = 0.7;

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
	float alive = 1.0 - min(INSTANCE_CUSTOM.g, 1.0);
	float st = INSTANCE_CUSTOM.a;
	float feeding = step(st, -0.5) * step(-1.5, st) * alive;
	float attacking = step(st, -1.5) * alive;
	float spd = max(st, 0.0);
	float move = smoothstep(0.04, 0.25, spd) * alive;
	float ph = INSTANCE_CUSTOM.b;
	float q = mix(q_min, q_max, smoothstep(run_lo, run_hi, spd));
	q = mix(q, max(q, 0.85), feeding);
	q = mix(q, q_min * 0.5, attacking);
	q *= alive;
	float P = q * pitch_max;
	float gs = sin(ph);
	float gc = cos(ph);
	bool left = (pid == 2 || pid == 4 || pid == 6 || pid == 8);
	float sgn = left ? 1.0 : -1.0;
	vec3 v = VERTEX;
	vec3 n = NORMAL;

	if (pid >= 6 && pid <= 9) {
		// legs: knee bend then hip swing (bigger strides when galloping)
		if (pid >= 8) {
			float bend = (max(0.0, sgn * gc) * knee_amp * move + q * 0.45 + feeding * 0.6);
			v = rot_x(v, knee_y, 0.0, bend);
			n = rot_xn(n, bend);
		}
		float swing = -sgn * gs * leg_amp * move * (1.0 + 0.5 * q) - feeding * 0.4;
		v = rot_x(v, hip.y, 0.0, swing);
		n = rot_xn(n, swing);
	} else if (pid >= 2 && pid <= 5) {
		// arms: elbow, then shoulder (point down to the ground on all fours)
		float slash = sin(TIME * 13.0 + sgn * 1.6);
		if (pid >= 4) {
			float elbow = -(0.25 + 0.45 * max(0.0, -sgn * gs)) * move - 0.15 - attacking * (0.6 + 0.4 * slash);
			v = rot_x(v, elbow_y, shoulder.z, elbow);
			n = rot_xn(n, elbow);
		}
		float arm = -P + sgn * gs * arm_amp * move * (1.0 + 0.4 * q) - feeding * 0.35
			+ attacking * (-1.9 + 0.9 * slash);
		v = rot_x(v, shoulder.y, shoulder.z, arm);
		n = rot_xn(n, arm);
	} else if (pid == 1) {
		// head: keep looking forward when hunched; peck when feeding
		float head = -P * 0.8 + feeding * (0.45 + 0.35 * sin(TIME * 9.0 + float(INSTANCE_ID))) + sin(ph * 2.0) * 0.05 * move;
		v = rot_x(v, neck_y, shoulder.z, head);
		n = rot_xn(n, head);
	} else if (pid == 11) {
		// tail / abdomen sway
		v.x += sin(ph * 0.5 + v.z * 1.5) * 0.06 * (move + 0.3) * clamp(-v.z, 0.0, 2.0);
	}
	if (pid <= 5) {
		// upper body pitches forward about the hips
		v = rot_x(v, hip.y, 0.0, P);
		n = rot_xn(n, P);
	}
	// breathing + crouch
	v.y -= q * quad_drop;
	if (pid == 0 || pid == 11) {
		v *= 1.0 + sin(TIME * 2.5 + float(INSTANCE_ID)) * 0.015 * alive;
	}
	VERTEX = v;
	NORMAL = normalize(n);
	// vertex colours are authored in sRGB: convert to linear for ALBEDO
	vcol = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
	fx = vec3(INSTANCE_CUSTOM.r, min(INSTANCE_CUSTOM.g, 1.0), step(1.5, INSTANCE_CUSTOM.g));
}

void fragment() {
	vec3 base = vcol.rgb;
	float dead = fx.g;
	float charred = fx.b;
	float lum = dot(base, vec3(0.3, 0.59, 0.11));
	base = mix(base, mix(vec3(lum), base, 0.6) * 0.5, dead);
	base = mix(base, vec3(0.05, 0.04, 0.035), charred);
	ALBEDO = mix(base, vec3(1.0), fx.r);
	// moist grey skin: soft sheen
	ROUGHNESS = mix(0.5, 0.85, dead);
	SPECULAR = 0.3;
	float glow = (1.0 - vcol.a) * (1.0 - dead);
	EMISSION = vcol.rgb * glow * 2.4 + vec3(1.0, 0.9, 0.8) * fx.r * 0.8 + vec3(1.0, 0.35, 0.05) * charred * 0.15;
	RIM = 0.18;
	RIM_TINT = 0.6;
}
