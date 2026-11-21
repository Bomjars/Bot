shader_type spatial;
// Alien planet surface: rust-ochre regolith with pebble speckle and dust
// drifts, dark banded basalt on cliffs (strata by height), pale dust on the
// plateaus, and the build grid only while building (grid_strength).

uniform vec3 regolith_a : source_color = vec3(0.27, 0.13, 0.10);
uniform vec3 regolith_b : source_color = vec3(0.45, 0.25, 0.17);
uniform vec3 dust : source_color = vec3(0.58, 0.40, 0.30);
uniform vec3 gravel : source_color = vec3(0.16, 0.11, 0.11);
uniform vec3 basalt_a : source_color = vec3(0.10, 0.08, 0.10);
uniform vec3 basalt_b : source_color = vec3(0.27, 0.18, 0.19);
uniform vec3 pad_color : source_color = vec3(0.36, 0.31, 0.29);
uniform vec3 core_pos = vec3(0.0, 0.0, 44.5);
uniform float pad_radius = 19.0;
uniform float grid_strength = 0.0;

varying vec3 wpos;
varying vec3 wnrm;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
	float a = 0.5; float s = 0.0;
	for (int k = 0; k < 4; k++) { s += a * vnoise(p); p *= 2.03; a *= 0.5; }
	return s;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float slope = 1.0 - clamp(wnrm.y, 0.0, 1.0);
	float n = fbm(wpos.xz * 0.18);
	float fine = vnoise(wpos.xz * 3.1);
	// regolith with pebbles and wind-blown dust streaks
	vec3 ground = mix(regolith_a, regolith_b, n);
	ground = mix(ground, dust, smoothstep(0.55, 0.85, fbm(wpos.xz * vec2(0.05, 0.22) + 3.0)) * 0.5);
	ground *= 0.85 + 0.3 * fine;
	ground = mix(ground, regolith_a * 0.55, step(0.93, hash(floor(wpos.xz * 6.0))) * 0.8); // pebbles
	// dark basalt gravel fields
	ground = mix(ground, gravel * (0.8 + 0.4 * fine), smoothstep(0.58, 0.72, fbm(wpos.xz * 0.07 + 11.0)) * 0.85);
	// crater bowls darker, rims dusty
	ground *= mix(0.62, 1.0, smoothstep(-0.45, 0.08, wpos.y));
	// basalt cliffs with strata bands
	float strata = sin(wpos.y * 5.5 + fbm(wpos.xz * 0.4) * 4.0) * 0.5 + 0.5;
	vec3 cliff = mix(basalt_a, basalt_b, strata * 0.7 + n * 0.3);
	// dusty plateau tops
	vec3 top = mix(basalt_b * 1.3, dust * 0.75, n * 0.8);
	float high = smoothstep(2.0, 3.0, wpos.y);
	vec3 flat_col = mix(ground, top, high);
	vec3 col = mix(flat_col, cliff, smoothstep(0.25, 0.55, slope));
	// levelled, compacted base pad around the outpost
	float d = length(wpos.xz - core_pos.xz);
	float pad = 1.0 - smoothstep(pad_radius - 3.0, pad_radius + 2.0, d);
	col = mix(col, pad_color * (0.9 + 0.2 * fine), pad * 0.55 * (1.0 - high));
	// build grid (flat walkable ground only)
	vec2 g = abs(fract(wpos.xz) - 0.5);
	float line = smoothstep(0.46, 0.5, max(g.x, g.y));
	col += vec3(0.25, 0.55, 0.65) * line * grid_strength * (1.0 - smoothstep(0.1, 0.3, slope)) * (1.0 - high);
	ALBEDO = col;
	ROUGHNESS = mix(0.95, 0.8, slope);
	SPECULAR = 0.25;
}
