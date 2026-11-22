shader_type spatial;
// GPU particles: the CPU writes a particle once when it spawns; its whole
// flight is computed here, so cost doesn't grow with the particle count.
// Per instance (MultiMesh): transform basis X = velocity, basis Y.x = ground
// height under the spawn point, basis Y.y = gravity scale, origin = spawn
// position. Colour rgb + a = glow. Custom: x spawn time, y life, z size.
render_mode cull_disabled, skip_vertex_transform;

uniform float now = 0.0;
varying vec4 c;

void vertex() {
	vec3 vel = MODEL_MATRIX[0].xyz;
	float ground = MODEL_MATRIX[1].x;
	float grav = MODEL_MATRIX[1].y;
	vec3 p0 = MODEL_MATRIX[3].xyz;
	float t = now - INSTANCE_CUSTOM.x;
	float life = INSTANCE_CUSTOM.y;
	float alive = step(0.0, t) * step(t, life) * step(0.0001, life);
	float g = 14.0 * grav;
	vec3 p;
	if (grav > 0.0) {
		// ballistic until it hits the ground, then it stays there (gibs stick)
		float disc = vel.y * vel.y + 2.0 * g * max(p0.y - ground, 0.0);
		float tl = (vel.y + sqrt(disc)) / g;
		float tt = min(t, tl);
		p = p0 + vel * tt;
		p.y = max(p0.y + vel.y * tt - 0.5 * g * tt * tt, ground);
	} else {
		p = p0 + vel * t;
		p.y -= 0.5 * g * t * t;   // negative gravity: drifts upward
	}
	float s = INSTANCE_CUSTOM.z * min(1.0, (life - t) / max(life, 0.0001) * 3.0) * alive;
	vec3 world = p + VERTEX * s;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// colours are authored in sRGB
	c = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
}

void fragment() {
	ALBEDO = c.rgb;
	ROUGHNESS = 0.6;
	EMISSION = c.rgb * c.a * 4.0;
}
