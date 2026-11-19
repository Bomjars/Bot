shader_type spatial;
// Particles / beams / splats. Instance colour rgb = colour, a = glow amount.
render_mode cull_disabled;
varying vec4 c;
void vertex() { c = COLOR; }
void fragment() {
	ALBEDO = c.rgb;
	ROUGHNESS = 0.6;
	EMISSION = c.rgb * c.a * 3.0;
}
