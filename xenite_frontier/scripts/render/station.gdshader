shader_type spatial;
// Station material (buildings, walls, doors, props): vertex colour albedo
// (x MultiMesh instance colour), vertex alpha < 1 = emissive lights/windows.
// Weathering, all procedural in world space: rust-brown dirt creeping up
// from the ground, regolith dust settled on top faces, grime streaks running
// down light panels, and per-surface wear. Damage (instance
// uniform for buildings, custom.x for wall MultiMeshes) spreads scorch marks
// with glowing embers when nearly destroyed.

instance uniform float damage = 0.0;
uniform float weathering = 1.0;

varying vec4 vcol;
varying vec3 wpos;
varying vec3 wn;
varying float ly;
varying float dmg;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void vertex() {
	// vertex colours are authored in sRGB: convert to linear for ALBEDO
	vcol = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	ly = VERTEX.y * length(MODEL_MATRIX[1].xyz);   // height above the model's base
	dmg = max(damage, INSTANCE_CUSTOM.x);
}

void fragment() {
	vec3 base = vcol.rgb;
	float glow = 1.0 - vcol.a;
	float solid = 1.0 - step(0.01, glow);
	float lum = dot(base, vec3(0.3, 0.59, 0.11));
	float vert = 1.0 - abs(wn.y);
	float n = vnoise(wpos.xz * 1.7 + wpos.y * 0.9);
	float n2 = vnoise(wpos.xz * 7.0 - wpos.y * 3.0);
	float w = weathering * solid;
	// per-surface wear: no two panels quite the same shade
	base *= 0.9 + 0.14 * n + 0.06 * n2;
	// rust-brown dirt creeping up from the ground
	float dirt = 1.0 - smoothstep(0.0, 0.45 + 0.45 * n, ly);
	base = mix(base, base * 0.5 + vec3(0.11, 0.05, 0.025), dirt * 0.7 * w);
	// grime streaks running down light vertical panels
	float along = abs(wn.x) > abs(wn.z) ? wpos.z : wpos.x;
	float st = vnoise(vec2(along * 9.0, wpos.y * 0.45 + n * 0.5));
	base *= 1.0 - smoothstep(0.6, 0.92, st) * 0.28 * vert * smoothstep(0.12, 0.35, lum) * w;
	// regolith dust settled on top faces
	float top = smoothstep(0.65, 0.95, wn.y);
	base = mix(base, vec3(0.3, 0.15, 0.08), top * (0.2 + 0.4 * n) * w);
	// scorch damage spreading as HP drops, embers when nearly destroyed
	float burn = vnoise(wpos.xz * 2.3 + wpos.y * 1.9) * 0.7 + n2 * 0.3;
	float sc = smoothstep(1.05 - dmg, 1.25 - dmg, burn) * smoothstep(0.12, 0.3, dmg);
	base = mix(base, vec3(0.012, 0.01, 0.009), sc * 0.88);
	float ember = sc * smoothstep(0.65, 0.9, dmg) * smoothstep(0.75, 0.95, vnoise(wpos.xz * 11.0 + vec2(TIME * 0.7, 0.0)));
	ALBEDO = base;
	EMISSION = vcol.rgb * glow * 2.2 + vec3(1.0, 0.32, 0.05) * ember * 2.0;
	ROUGHNESS = clamp(0.55 + 0.3 * dirt + 0.2 * top + 0.25 * sc, 0.0, 1.0);
	METALLIC = 0.15 * (1.0 - dirt) * (1.0 - sc);
}
