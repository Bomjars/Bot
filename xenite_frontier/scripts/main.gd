extends Node3D
## M1 entry point: swarm test range. Builds the world, flow field, swarm,
## camera and benchmark HUD.
##
## Command line (after `--`):
##   --benchmark[=N]   run the scripted benchmark with N aliens and quit
##   --aliens=N        start with N aliens

var map: OutpostMap
var field: FlowField
var swarm: Swarm
var cam: RTSCamera
var hud: BenchmarkHUD
var bench: BenchmarkRunner
var target_count := 3000
var _heat_on := false
var _heat_shot := OS.get_cmdline_user_args().has("--heatmap")


func _ready() -> void:
	_build_environment()

	var tr := GameConfig.section("test_range")
	map = OutpostMap.new()
	map.name = "OutpostMap"
	add_child(map)
	map.generate_test_range(int(tr.get("width", 200)), int(tr.get("height", 140)), int(tr.get("seed", 1337)))

	field = FlowField.new(map)
	field.build()
	print("[flowfield] %dx%d built in %.2f ms" % [map.w, map.h, field.build_usec / 1000.0])
	map.changed.connect(_on_map_changed)
	field.rebuilt.connect(_on_field_rebuilt)

	swarm = Swarm.new()
	swarm.name = "Swarm"
	add_child(swarm)
	swarm.setup(map, field, GameConfig.alien_defs)

	cam = RTSCamera.new()
	cam.name = "CameraRig"
	add_child(cam)
	cam.position = map.core_center + Vector3(0, 0, -20)
	cam.bounds = Rect2(map.origin, Vector2(map.w, map.h))
	cam.distance = 75.0
	cam._target_distance = 75.0

	bench = BenchmarkRunner.new()
	bench.name = "Benchmark"
	bench.swarm = swarm
	add_child(bench)
	bench.finished.connect(_on_bench_finished)

	hud = BenchmarkHUD.new()
	hud.main = self
	add_child(hud)

	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	target_count = int(GameConfig.section("swarm").get("start_aliens", 3000))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--benchmark"):
			bench.quit_when_done = true
			var parts := arg.split("=")
			bench.start(int(parts[1]) if parts.size() > 1 else -1)
		elif arg.begins_with("--aliens="):
			target_count = int(arg.split("=")[1])
		elif arg.begins_with("--screenshot="):
			_screenshot_after(arg.split("=")[1])


## Dev helper: `-- --aliens=N --screenshot=path.png` saves a frame after 12s.
func _screenshot_after(path: String) -> void:
	# simulate ~10 s at 60 Hz up front so slow (software) renderers show a horde
	for k in 600:
		swarm.approach_population(target_count)
		swarm.simulate(1.0 / 60.0)
	var focus := OS.get_cmdline_user_args().filter(func(a): return a.begins_with("--cam="))
	if not focus.is_empty():
		var v: PackedStringArray = focus[0].split("=")[1].split(",")
		cam.position = Vector3(float(v[0]), 0, float(v[1]))
		cam._target_distance = float(v[2])
		cam.distance = float(v[2])
	await get_tree().create_timer(3.0).timeout
	if _heat_shot:
		_heat_on = true
		map.show_heatmap(field, true)
		await get_tree().create_timer(0.5).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[screenshot] saved ", path)
	get_tree().quit()


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.03, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.42, 0.5)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.25, 0.12, 0.12)
	env.fog_density = 0.004
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.78, 0.62)
	sun.light_energy = 1.1
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)


func _process(_delta: float) -> void:
	field.poll()
	var want := bench.desired_population()
	swarm.approach_population(want if want >= 0 else target_count)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("bench_run") and not bench.running():
		bench.start()
	elif bench.running():
		return  # don't disturb a benchmark in progress
	elif event.is_action_pressed("bench_more"):
		target_count += 1000
	elif event.is_action_pressed("bench_less"):
		target_count = maxi(0, target_count - 1000)
	elif event.is_action_pressed("bench_preset_1"):
		target_count = 1000
	elif event.is_action_pressed("bench_preset_2"):
		target_count = 5000
	elif event.is_action_pressed("bench_preset_3"):
		target_count = 10000
	elif event.is_action_pressed("bench_preset_4"):
		target_count = 20000
	elif event.is_action_pressed("pause"):
		swarm.paused = not swarm.paused
	elif event.is_action_pressed("debug_flowfield"):
		_heat_on = not _heat_on
		map.show_heatmap(field, _heat_on)
	elif event.is_action_pressed("debug_hud"):
		hud.visible = not hud.visible
	elif event.is_action_pressed("reset_walls"):
		map.reset_to_initial()
	elif event.is_action_pressed("primary"):
		var pos: Vector2 = get_viewport().get_mouse_position()
		if not (event is InputEventMouseButton):
			pos = get_viewport().get_visible_rect().size * 0.5  # gamepad: screen centre
		var hit: Variant = cam.ground_point(pos)
		if hit != null:
			var c := map.world_to_cell(hit)
			map.toggle_wall(c.x, c.y)


func _on_map_changed() -> void:
	field.request_rebuild()


func _on_field_rebuilt() -> void:
	if _heat_on:
		map.show_heatmap(field, true)


func _on_bench_finished(report: String) -> void:
	hud.show_report(report)
