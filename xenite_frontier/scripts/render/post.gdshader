shader_type canvas_item;
// Screen post-effect over the 3D view (UI is drawn on top, untouched):
// soft vignette, fine film grain and a hint of colour fringing at the edges.
uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;
uniform float vignette = 0.28;
uniform float grain = 0.035;
uniform float fringe = 0.0004;

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = uv - 0.5;
	float r2 = dot(d, d);
	vec3 col;
	col.r = texture(screen, uv + d * fringe * r2 * 8.0).r;
	col.g = texture(screen, uv).g;
	col.b = texture(screen, uv - d * fringe * r2 * 8.0).b;
	col *= 1.0 - vignette * smoothstep(0.08, 0.55, r2);
	float n = hash(uv * vec2(1931.0, 1173.0) + fract(TIME * 13.7)) - 0.5;
	col += n * grain * (1.0 - col * 0.6);
	COLOR = vec4(col, 1.0);
}
