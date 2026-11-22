class_name Graphics
extends Node
## Lighting, atmosphere and the graphics quality setting.
##
## Builds the world environment (sky, sun, fill, fog, ground haze, bloom,
## ambient occlusion, colour grading), the screen post-effect (vignette and
## film grain) and wind-blown dust around the camera. Quality presets (Low /
## Medium / High / Ultra) live in data/game_config.json "graphics"; the
## player's choice is saved in user://settings.cfg. F2 cycles it in game.

const SETTINGS_PATH := "user://settings.cfg"
const ORDER := ["low", "medium", "high", "ultra"]

var quality := "high"
var env: Environment
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var haze: FogVolume
var post: CanvasLayer
var dust: GPUParticles3D
var sand: GPUParticles3D
var _follow: Node3D       # dust follows what the camera looks at
var map: OutpostMap       # terrain relief + pebble fields follow the quality


func setup(world_parent: Node, follow: Node3D) -> void:
	_follow = follow
	quality = _load_choice()
	_build_environment(world_parent)
	_build_post()
	_build_dust(world_parent)
	apply(quality)


func preset(q: String) -> Dictionary:
	var g := GameConfig.section("graphics")
	var p: Dictionary = g.get("presets", {}).get(q, {})
	return p


## Applies a preset (and remembers it).
func apply(q: String) -> void:
	if not q in ORDER:
		q = "high"
	quality = q
	var p := preset(q)
	var vp := get_viewport()
	# anti-aliasing
	var msaa := int(p.get("msaa", 2))
	vp.msaa_3d = Viewport.MSAA_DISABLED if msaa <= 0 else (Viewport.MSAA_2X if msaa == 2 else (Viewport.MSAA_4X if msaa == 4 else Viewport.MSAA_8X))
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if p.get("fxaa", false) else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.scaling_3d_scale = float(p.get("render_scale", 1.0))
	# shadows: atlas size, soft (PCSS) filter, distance
	RenderingServer.directional_shadow_atlas_set_size(int(p.get("shadow_size", 2048)), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(int(p.get("shadow_soft", 2)))
	RenderingServer.positional_soft_shadow_filter_set_quality(int(p.get("shadow_soft", 2)))
	sun.directional_shadow_max_distance = float(p.get("shadow_distance", 140.0))
	sun.light_angular_distance = 1.2 if int(p.get("shadow_soft", 2)) >= 3 else 0.0
	# screen-space effects
	env.ssao_enabled = bool(p.get("ssao", true))
	RenderingServer.environment_set_ssao_quality(int(p.get("ssao_quality", 2)), int(p.get("ssao_quality", 2)) < 2, 0.5, 2, 50, 300)
	env.ssil_enabled = bool(p.get("ssil", false))
	env.glow_enabled = bool(p.get("glow", true))
	# atmosphere: volumetric ground haze (light shafts, floodlight beams) or
	# a cheap height fog on lower settings
	var vol := bool(p.get("volumetric_fog", false))
	env.volumetric_fog_enabled = vol
	haze.visible = vol
	env.fog_height_density = 0.0 if vol else 0.06
	if vol:
		var vs := int(p.get("fog_volume_size", 64))
		RenderingServer.environment_set_volumetric_fog_volume_size(vs, int(vs * 0.75))
		RenderingServer.environment_set_volumetric_fog_filter_active(true)
	post.visible = bool(p.get("post", true))
	if map:
		map.set_surface_detail(float(p.get("terrain_detail", 1.0)), bool(p.get("pebbles", true)))
	var dust_amt := int(p.get("dust", 0))
	dust.emitting = dust_amt > 0
	dust.visible = dust_amt > 0
	if dust_amt > 0:
		dust.amount = dust_amt
		sand.amount = maxi(16, dust_amt / 2)
	sand.emitting = dust_amt > 0
	sand.visible = dust_amt > 0
	_save_choice(q)


func cycle() -> String:
	apply(ORDER[(ORDER.find(quality) + 1) % ORDER.size()])
	return quality


func label() -> String:
	return str(preset(quality).get("name", quality.capitalize()))


func _process(_dt: float) -> void:
	if _follow and dust:
		var at := _follow.global_position
		dust.global_position = Vector3(at.x, 0.0, at.z)
		sand.global_position = Vector3(at.x, 0.0, at.z)


# ------------------------------------------------------------ environment

func _build_environment(parent: Node) -> void:
	# dim violet sky with a ringed gas giant and a small moon
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = preload("res://scripts/render/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.6
	env.ambient_light_color = Color(0.5, 0.4, 0.58)
	env.ambient_light_energy = 1.1
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.18
	env.tonemap_white = 6.0
	# bloom: lamps, windows, eyes, acid and muzzle flashes glow softly
	env.glow_enabled = true
	env.glow_normalized = false
	env.glow_intensity = 0.55
	env.glow_strength = 1.0
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 0.95
	env.glow_hdr_scale = 1.6
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	for lv in 7:
		env.set_glow_level(lv, 1.0 if lv in [1, 2, 3, 4] else 0.0)
	# contact shadows and bounce light
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.6
	env.ssao_power = 1.4
	env.ssao_detail = 0.6
	env.ssao_light_affect = 0.15
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.8
	# distance haze + low ground fog (cheap path)
	env.fog_enabled = true
	env.fog_light_color = Color(0.47, 0.34, 0.29)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.25
	env.fog_density = 0.0022
	env.fog_sky_affect = 0.35
	env.fog_height = 0.8
	env.fog_height_density = 0.06
	# volumetric fog (High / Ultra): faint global dust, sun glare forward
	env.volumetric_fog_density = 0.0025
	env.volumetric_fog_albedo = Color(0.82, 0.7, 0.64)
	env.volumetric_fog_emission = Color(0.06, 0.03, 0.06)
	env.volumetric_fog_emission_energy = 1.0
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 140.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_ambient_inject = 0.35
	env.volumetric_fog_sky_affect = 0.25
	# grade: violet-lifted shadows, warm highlights, a touch more contrast
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.0
	env.adjustment_contrast = 1.08
	env.adjustment_brightness = 1.0
	var grade := Gradient.new()
	grade.set_offset(0, 0.0)
	grade.set_color(0, Color(0.035, 0.015, 0.05))
	grade.set_offset(1, 1.0)
	grade.set_color(1, Color(1.0, 0.97, 0.9))
	grade.add_point(0.5, Color(0.51, 0.49, 0.465))
	var gt := GradientTexture1D.new()
	gt.gradient = grade
	gt.width = 256
	env.adjustment_color_correction = gt
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	parent.add_child(we)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.84, 0.7)
	sun.light_energy = 1.45
	sun.rotation_degrees = Vector3(-33, -40, 0)   # low sun: relief casts long shadows
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 140.0
	sun.light_volumetric_fog_energy = 1.4
	parent.add_child(sun)
	# cool bounce from the opposite side so shadowed cliffs read
	fill = DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(0.55, 0.42, 0.85)
	fill.light_energy = 0.5
	fill.rotation_degrees = Vector3(-30, 150, 0)
	fill.light_volumetric_fog_energy = 0.0
	parent.add_child(fill)

	# low dust haze hugging the ground across the whole map (volumetric only)
	haze = FogVolume.new()
	haze.name = "GroundHaze"
	haze.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	haze.size = Vector3(420, 14, 300)
	haze.position = Vector3(0, 3.0, 0)
	var fm := FogMaterial.new()
	fm.density = 0.035
	fm.albedo = Color(0.86, 0.72, 0.62)
	fm.emission = Color(0.05, 0.02, 0.05)
	fm.height_falloff = 0.55
	fm.edge_fade = 0.6
	var noise := FastNoiseLite.new()
	noise.frequency = 0.025
	noise.fractal_octaves = 3
	var nt := NoiseTexture3D.new()
	nt.width = 64
	nt.height = 16
	nt.depth = 64
	nt.noise = noise
	nt.seamless = true
	fm.density_texture = nt
	haze.material = fm
	parent.add_child(haze)


# ------------------------------------------------------------ post effect

func _build_post() -> void:
	post = CanvasLayer.new()
	post.name = "PostFX"
	post.layer = -1          # over the 3D view, under every UI layer
	add_child(post)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = preload("res://scripts/render/post.gdshader")
	rect.material = m
	post.add_child(rect)


# ------------------------------------------------------------ wind-blown dust

func _build_dust(parent: Node) -> void:
	var soft := GradientTexture2D.new()
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(1.0, 0.5)
	var gr := Gradient.new()
	gr.set_color(0, Color(1, 1, 1, 1))
	gr.set_color(1, Color(1, 1, 1, 0))
	soft.gradient = gr
	soft.width = 32
	soft.height = 32

	# floating motes drifting with the wind
	dust = GPUParticles3D.new()
	dust.name = "DustMotes"
	dust.amount = 400
	dust.lifetime = 9.0
	dust.preprocess = 9.0
	dust.visibility_aabb = AABB(Vector3(-60, -2, -60), Vector3(120, 14, 120))
	dust.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(45, 1.4, 35)
	pm.direction = Vector3(1, 0.05, 0.35)
	pm.spread = 12.0
	pm.initial_velocity_min = 1.2
	pm.initial_velocity_max = 3.0
	pm.gravity = Vector3(0, -0.02, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.6
	pm.turbulence_noise_scale = 6.0
	pm.scale_min = 0.012
	pm.scale_max = 0.03
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0))
	fade.add_point(0.2, Color(1, 1, 1, 1))
	fade.add_point(0.8, Color(1, 1, 1, 1))
	fade.set_color(fade.get_point_count() - 1, Color(1, 1, 1, 0))
	var ft := GradientTexture1D.new()
	ft.gradient = fade
	pm.color_ramp = ft
	pm.color = Color(0.62, 0.44, 0.34, 0.3)
	dust.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var qm := StandardMaterial3D.new()
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	qm.vertex_color_use_as_albedo = true
	qm.albedo_texture = soft
	qm.disable_receive_shadows = true
	q.material = qm
	dust.draw_pass_1 = q
	dust.position.y = 1.5
	parent.add_child(dust)

	# streaks of sand skimming the ground
	sand = GPUParticles3D.new()
	sand.name = "BlowingSand"
	sand.amount = 200
	sand.lifetime = 2.5
	sand.preprocess = 2.5
	sand.visibility_aabb = AABB(Vector3(-60, -2, -60), Vector3(120, 6, 120))
	sand.local_coords = false
	var sm := ParticleProcessMaterial.new()
	sm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	sm.emission_box_extents = Vector3(45, 0.25, 35)
	sm.direction = Vector3(1, 0.0, 0.35)
	sm.spread = 6.0
	sm.initial_velocity_min = 6.0
	sm.initial_velocity_max = 11.0
	sm.gravity = Vector3.ZERO
	sm.particle_flag_align_y = true
	sm.scale_min = 0.6
	sm.scale_max = 1.4
	sm.color_ramp = ft
	sm.color = Color(0.7, 0.48, 0.34, 0.2)
	sand.process_material = sm
	var sq := QuadMesh.new()
	sq.size = Vector2(0.06, 0.9)
	var sqm := qm.duplicate() as StandardMaterial3D
	sqm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sq.material = sqm
	sand.draw_pass_1 = sq
	sand.position.y = 0.3
	parent.add_child(sand)


# ------------------------------------------------------------ persistence

func _load_choice() -> String:
	var cf := ConfigFile.new()
	var def := str(GameConfig.section("graphics").get("default", "high"))
	if cf.load(SETTINGS_PATH) != OK:
		return def
	return str(cf.get_value("graphics", "quality", def))


func _save_choice(q: String) -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	cf.set_value("graphics", "quality", q)
	cf.save(SETTINGS_PATH)
