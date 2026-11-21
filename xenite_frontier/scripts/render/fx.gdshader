shader_type spatial;
// Particles / beams / splats. Instance colour rgb = colour, a = glow amount.
render_mode cull_disabled;
varying vec4 c;
void vertex() {
	// colours are authored in sRGB
	c = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
}
void fragment() {
	ALBEDO = c.rgb;
	ROUGHNESS = 0.6;
	EMISSION = c.rgb * c.a * 4.0;
}
