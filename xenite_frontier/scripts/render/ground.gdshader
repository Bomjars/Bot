shader_type spatial;
// Hostile alien regolith with a faint build grid.

uniform vec3 soil_a : source_color = vec3(0.16, 0.10, 0.09);
uniform vec3 soil_b : source_color = vec3(0.26, 0.17, 0.13);
uniform float grid_strength = 0.12;

varying vec3 wpos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }

void fragment() {
	float n = vnoise(wpos.xz * 0.15) * 0.6 + vnoise(wpos.xz * 0.9) * 0.4;
	vec3 col = mix(soil_a, soil_b, n);
	vec2 g = abs(fract(wpos.xz) - 0.5);
	float line = smoothstep(0.47, 0.5, max(g.x, g.y));
	col += vec3(0.25, 0.35, 0.4) * line * grid_strength;
	ALBEDO = col;
	ROUGHNESS = 0.95;
}
