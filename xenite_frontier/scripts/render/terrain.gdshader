shader_type spatial;
// Alien planet surface. Colour: rust-ochre regolith in broad patches, dark
// basalt gravel fields, pale dust drifts gathering in hollows, banded basalt
// cliffs and dusty plateau tops, a compacted pad around the outpost and the
// build grid while building. Relief (`detail`, set by the graphics quality):
// a procedural micro height field bends the normals - wind ripples in the
// sand, pebbles with contact shading, dried-mud cracks in the low basins and
// rough ledges on the cliffs - fading out with distance so it never shimmers.
// Vertex colour r = baked concavity (creases at cliff feet are darker).

uniform vec3 regolith_a : source_color = vec3(0.40, 0.18, 0.09);
uniform vec3 regolith_b : source_color = vec3(0.58, 0.30, 0.15);
uniform vec3 ochre : source_color = vec3(0.62, 0.36, 0.16);
uniform vec3 dust : source_color = vec3(0.68, 0.45, 0.30);
uniform vec3 gravel : source_color = vec3(0.22, 0.11, 0.08);
uniform vec3 basalt_a : source_color = vec3(0.24, 0.10, 0.06);
uniform vec3 basalt_b : source_color = vec3(0.56, 0.27, 0.13);
uniform vec3 pad_color : source_color = vec3(0.38, 0.34, 0.31);
uniform vec3 core_pos = vec3(0.0, 0.0, 44.5);
uniform float pad_radius = 19.0;
uniform float grid_strength = 0.0;
uniform float detail = 1.0;
uniform vec2 wind = vec2(0.94, 0.33);

varying vec3 wpos;
varying vec3 wnrm;
varying float vcav;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 hash2(vec2 p) {
	return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453);
}
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
// x: distance to the nearest cell point, y: distance to the cell edge, z: cell id
vec3 voronoi(vec2 x) {
	vec2 n = floor(x); vec2 f = fract(x);
	float f1 = 8.0; float f2 = 8.0; float id = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 r = g + hash2(n + g) - f;
			float d = dot(r, r);
			if (d < f1) { f2 = f1; f1 = d; id = hash(n + g); }
			else if (d < f2) { f2 = d; }
		}
	}
	return vec3(sqrt(f1), sqrt(f2) - sqrt(f1), id);
}

// masks shared by colour and relief
struct Masks { float cliff; float high; float dusty; float gravelly; float basin; float pad; };

Masks masks(vec3 p, vec3 n, float cav) {
	Masks m;
	float slope = 1.0 - clamp(n.y, 0.0, 1.0);
	m.cliff = smoothstep(0.25, 0.55, slope);
	m.high = smoothstep(2.0, 3.0, p.y);
	m.dusty = smoothstep(0.5, 0.8, fbm(p.xz * vec2(0.05, 0.2) + 3.0)) * 0.6 + (1.0 - cav) * 1.6;
	m.dusty = clamp(m.dusty, 0.0, 1.0) * (1.0 - m.cliff);
	m.gravelly = smoothstep(0.58, 0.72, fbm(p.xz * 0.07 + 11.0)) * (1.0 - m.cliff);
	m.basin = (1.0 - smoothstep(-0.55, -0.1, p.y)) * (1.0 - m.cliff);
	float d = length(p.xz - core_pos.xz);
	m.pad = (1.0 - smoothstep(pad_radius - 3.0, pad_radius + 2.0, d)) * (1.0 - m.high);
	return m;
}

// micro height (metres) at world point p
float micro(vec3 p, Masks m) {
	float h = 0.0;
	// wind ripples in the sand: across the wind, warped by noise
	vec2 perp = vec2(-wind.y, wind.x);
	float ph = dot(p.xz, wind) * 7.0 + fbm(p.xz * 0.6) * 5.0;
	float rip = sin(ph);
	h += rip * rip * 0.018 * m.dusty * (1.0 - m.pad) * (1.0 - m.basin * 0.7);
	// pebbles: little domes, denser in gravel fields
	vec3 v = voronoi(p.xz * 4.5);
	float dens = 0.1 + 0.45 * m.gravelly;
	float pr = 0.14 + 0.22 * fract(v.z * 7.13);           // pebble radius varies
	float dome = 1.0 - smoothstep(0.0, pr, v.x);
	float peb = step(v.z, dens) * sqrt(max(dome, 0.0));
	h += peb * 0.045 * (1.0 - m.cliff) * (1.0 - m.pad * 0.6);
	// dried-mud cracks in the low basins
	vec3 c = voronoi(p.xz * 0.85 + 7.0);
	h -= (1.0 - smoothstep(0.0, 0.05, c.y)) * 0.05 * m.basin;
	// cliffs: ledges of banded basalt and rough rock
	float led = smoothstep(0.3, 0.5, fract(p.y * 1.7 + fbm(p.xz * 0.35) * 0.7));
	h += (led * 0.1 + fbm(p.xz * 1.7 + p.y * 1.3) * 0.12) * m.cliff;
	// plateau tops: wind-scoured rock
	h += fbm(p.xz * 2.4) * 0.04 * m.high * (1.0 - m.cliff);
	return h;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vcav = COLOR.r;
}

void fragment() {
	float cam_d = length(wpos - CAMERA_POSITION_WORLD);
	float near = (1.0 - smoothstep(35.0, 95.0, cam_d)) * detail;
	Masks m = masks(wpos, wnrm, vcav);
	float n = fbm(wpos.xz * 0.18);
	float fine = vnoise(wpos.xz * 3.1);
	float patchy = fbm(wpos.xz * 0.022 + 40.0);

	// ---- colour
	vec3 ground = mix(regolith_a, regolith_b, n);
	ground = mix(ground, ochre, smoothstep(0.45, 0.75, patchy) * 0.55);        // broad ochre patches
	ground = mix(ground, dust, m.dusty * 0.55);                                  // dust drifts and hollows
	ground *= 0.85 + 0.3 * fine;
	ground = mix(ground, gravel * (0.8 + 0.4 * fine), m.gravelly * 0.85);         // basalt gravel fields
	ground *= mix(0.62, 1.0, smoothstep(-0.45, 0.08, wpos.y));                    // crater bowls darker
	float strata = sin(wpos.y * 5.5 + fbm(wpos.xz * 0.4) * 4.0) * 0.5 + 0.5;
	vec3 cliff = mix(basalt_a, basalt_b, strata * 0.7 + n * 0.3);
	vec3 top = mix(basalt_b * 0.9, dust * 0.8, n * 0.8);
	vec3 col = mix(ground, top, m.high);
	col = mix(col, cliff, m.cliff);
	col = mix(col, pad_color * (0.9 + 0.2 * fine), m.pad * 0.55);

	// ---- relief: bend the normal along the micro height field
	vec3 N = wnrm;
	float rough = mix(0.95, 0.82, m.cliff);
	if (near > 0.01) {
		float e = 0.035;
		float h0 = micro(wpos, m);
		float hx = micro(wpos + vec3(e, 0.0, 0.0), m);
		float hy = micro(wpos + vec3(0.0, e, 0.0), m);
		float hz = micro(wpos + vec3(0.0, 0.0, e), m);
		vec3 grad = vec3(hx - h0, hy - h0, hz - h0) / e;
		grad -= dot(grad, wnrm) * wnrm;               // keep it in the surface
		N = normalize(wnrm - grad * near * 1.4);
		// pebbles and ripple crests catch the light, cracks and pebble feet darken
		vec3 v = voronoi(wpos.xz * 4.5);
		float dens = 0.1 + 0.45 * m.gravelly;
		float peb = step(v.z, dens) * (1.0 - m.cliff) * (1.0 - m.pad * 0.6);
		float pr = 0.14 + 0.22 * fract(v.z * 7.13);
		float core = 1.0 - smoothstep(pr * 0.7, pr, v.x);
		// each stone its own shade: dark basalt to pale sandstone
		vec3 stone = mix(gravel * 1.3, dust * 1.1, fract(v.z * 31.7));
		col = mix(col, stone, peb * core * near * 0.85);
		rough = mix(rough, 0.68, peb * core * near);
		vec3 c = voronoi(wpos.xz * 0.85 + 7.0);
		col *= 1.0 - (1.0 - smoothstep(0.0, 0.05, c.y)) * 0.45 * m.basin * near;
	}
	// creases at the feet of cliffs and walls of craters
	col *= mix(0.55, 1.0, vcav);

	// build grid (flat walkable ground only)
	vec2 g = abs(fract(wpos.xz) - 0.5);
	float line = smoothstep(0.46, 0.5, max(g.x, g.y));
	col += vec3(0.25, 0.55, 0.65) * line * grid_strength * (1.0 - m.cliff) * (1.0 - m.high);
	ALBEDO = col;
	NORMAL = normalize((VIEW_MATRIX * vec4(N, 0.0)).xyz);
	ROUGHNESS = rough;
	SPECULAR = 0.28;
}
