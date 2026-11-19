shader_type spatial;
// Shared alien + corpse material. Part colours come from vertex colours;
// vertex alpha < 1 marks bioluminescent parts (emissive).
// INSTANCE_CUSTOM: r = hit flash, g = dead (corpse), b = charred, a = unused.
// Gait animation runs on the GPU: zero CPU cost per alien.

uniform float gait_speed = 14.0;
uniform float gait_amp = 0.06;

varying vec4 vcol;
varying vec3 fx;

void vertex() {
	float alive = 1.0 - INSTANCE_CUSTOM.g;
	float ph = float(INSTANCE_ID) * 2.3999;
	float s = sin(TIME * gait_speed + ph) * alive;
	float leg = 1.0 - smoothstep(0.0, 0.35, VERTEX.y);
	VERTEX.z += s * 0.12 * leg * sign(VERTEX.x + 0.001);
	VERTEX.y += abs(s) * gait_amp * (1.0 - leg);
	vcol = COLOR;
	fx = INSTANCE_CUSTOM.rgb;
}

void fragment() {
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	vec3 base = vcol.rgb;
	float dead = fx.g;
	float charred = fx.b;
	// corpses: darker, desaturated; charred: near black
	float lum = dot(base, vec3(0.3, 0.59, 0.11));
	base = mix(base, mix(vec3(lum), base, 0.5) * 0.45, dead);
	base = mix(base, vec3(0.05, 0.04, 0.035), charred);
	ALBEDO = mix(base, vec3(1.0), fx.r);
	ROUGHNESS = mix(0.55, 0.85, dead);
	float glow = (1.0 - vcol.a) * (1.0 - dead);
	EMISSION = vcol.rgb * glow * 0.9 + vec3(1.0, 0.9, 0.8) * fx.r * 0.8 + vec3(1.0, 0.35, 0.05) * charred * 0.15;
	RIM = 0.25;
	RIM_TINT = 0.3;
}
