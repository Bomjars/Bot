shader_type spatial;
// Shared alien material. Part colours come from vertex colours; vertex alpha
// < 1 marks bioluminescent parts (emissive). INSTANCE_CUSTOM.r = hit flash
// (used from M2). Gait animation runs on the GPU: zero CPU cost per alien.

uniform float gait_speed = 14.0;
uniform float gait_amp = 0.06;

varying vec4 vcol;
varying float flash;

void vertex() {
	float ph = float(INSTANCE_ID) * 2.3999;
	float s = sin(TIME * gait_speed + ph);
	// legs (low vertices) swing, body bobs
	float leg = 1.0 - smoothstep(0.0, 0.35, VERTEX.y);
	VERTEX.z += s * 0.12 * leg * sign(VERTEX.x + 0.001);
	VERTEX.y += abs(s) * gait_amp * (1.0 - leg);
	vcol = COLOR;
	flash = INSTANCE_CUSTOM.r;
}

void fragment() {
	// faceted low-poly normals
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	vec3 base = vcol.rgb;
	ALBEDO = mix(base, vec3(1.0), flash);
	ROUGHNESS = 0.55;
	float glow = 1.0 - vcol.a;
	EMISSION = base * glow * 0.9 + vec3(1.0, 0.9, 0.8) * flash * 0.8;
	RIM = 0.25;
	RIM_TINT = 0.3;
}
