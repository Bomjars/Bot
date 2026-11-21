shader_type sky;
// Dim violet sky with a large ringed gas giant and one small moon.

uniform vec3 zenith : source_color = vec3(0.06, 0.035, 0.11);
uniform vec3 horizon : source_color = vec3(0.30, 0.16, 0.25);
uniform vec3 ground : source_color = vec3(0.32, 0.15, 0.09);
uniform vec3 planet_dir = vec3(-0.32, 0.16, -1.0);
uniform float planet_radius = 0.26;
uniform vec3 band_a : source_color = vec3(0.50, 0.33, 0.30);
uniform vec3 band_b : source_color = vec3(0.78, 0.60, 0.48);
uniform vec3 ring_col : source_color = vec3(0.72, 0.62, 0.55);
uniform vec3 moon_dir = vec3(0.45, 0.2, -0.9);
uniform float moon_radius = 0.035;

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 col = mix(horizon, zenith, smoothstep(-0.02, 0.55, h));
	if (h < 0.0) {
		col = mix(horizon * 0.7, ground, smoothstep(0.0, -0.25, h));
	}
	// faint stars high up
	vec2 sp = floor(d.xz / max(0.05, d.y + 0.2) * 220.0);
	col += vec3(step(0.9975, hash(sp))) * smoothstep(0.15, 0.6, h) * 0.6;

	// gas giant (local disc coordinates)
	vec3 pdir = normalize(planet_dir);
	vec3 right = normalize(cross(pdir, vec3(0.0, 1.0, 0.0)));
	vec3 up = cross(right, pdir);
	float s = sin(planet_radius);
	vec2 uv = vec2(dot(d, right), dot(d, up)) / s;
	float front = step(0.0, dot(d, pdir));
	float r = length(uv);
	// rings: tilted ellipse around the planet
	float tilt = 0.32;
	vec2 ru = vec2(uv.x * cos(tilt) - uv.y * sin(tilt), uv.x * sin(tilt) + uv.y * cos(tilt));
	float er = length(vec2(ru.x, ru.y / 0.22));
	float ring = smoothstep(1.32, 1.38, er) * (1.0 - smoothstep(2.15, 2.25, er)) * front;
	ring *= 0.55 + 0.45 * sin(er * 38.0);
	bool ring_front = ru.y < 0.0;
	if (r < 1.0 && front > 0.5) {
		float bands = sin(uv.y * 16.0 + sin(uv.x * 4.0 + uv.y * 3.0) * 1.2) * 0.5 + 0.5;
		vec3 pc = mix(band_a, band_b, bands);
		vec3 nrm = normalize(vec3(uv, sqrt(max(0.0, 1.0 - r * r))));
		float lit = clamp(dot(nrm, normalize(vec3(0.55, 0.35, 0.75))), 0.0, 1.0);
		vec3 disc = pc * (0.08 + 0.92 * lit);
		disc = mix(disc, horizon, 0.25);
		col = mix(col, disc, smoothstep(1.0, 0.985, r));
		if (ring_front) {
			col = mix(col, ring_col * 0.8, ring * 0.85);
		}
	} else {
		col = mix(col, ring_col * 0.7, ring * 0.75);
	}
	// small moon
	vec3 mdir = normalize(moon_dir);
	float md = acos(clamp(dot(d, mdir), -1.0, 1.0));
	col = mix(col, vec3(0.62, 0.6, 0.62) * (0.6 + 0.4 * hash(floor(d.xy * 900.0))), 1.0 - smoothstep(moon_radius * 0.92, moon_radius, md));
	// sun
	if (LIGHT0_ENABLED) {
		float sd = acos(clamp(dot(d, -LIGHT0_DIRECTION), -1.0, 1.0));
		col += LIGHT0_COLOR * (1.0 - smoothstep(0.012, 0.02, sd)) * 3.0 + LIGHT0_COLOR * exp(-sd * 9.0) * 0.08;
	}
	COLOR = col;
}
