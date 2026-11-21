shader_type spatial;
// Station material: vertex colour albedo (x MultiMesh instance colour for
// damage tint), vertex alpha < 1 = emissive lights/windows.
varying vec4 vcol;
void vertex() {
	// vertex colours are authored in sRGB: convert to linear for ALBEDO
	vcol = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
}
void fragment() {
	ALBEDO = vcol.rgb;
	float glow = 1.0 - vcol.a;
	EMISSION = vcol.rgb * glow * 2.2;
	ROUGHNESS = 0.6;
	METALLIC = 0.15;
}
