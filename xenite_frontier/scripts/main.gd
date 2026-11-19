extends Node3D
## M2 entry point: combat range. Builds world, flow fields, swarm, combat,
## structures, corpses, fx, camera, HUD and build bar, then drives the frame:
##   poll fields -> swarm sim (threaded) -> swarm events -> spatial grid ->
##   turrets -> projectiles -> deaths/corpses -> spawning -> uploads.
##
## Command line (after `--`):
##   --benchmark[=N]   scripted benchmark with N aliens, then quit
##   --aliens=N        start swarm pressure at N
##   --combat-test[=S] headless combat soak for S seconds, prints stats, quits
##   --screenshot=PATH dev: warm up, save a frame, quit (with --cam=x,z,dist)

var map: OutpostMap
var field: FlowField
var bfield: FlowField
var swarm: Swarm
var combat: Combat
var structures: Structures
var corpses: Corpses
var fx: Fx
var cam: RTSCamera
var hud: Hud
var build: BuildBar
var bench: BenchmarkRunner
var target_count := 1500
var overrun := false

var _heat_on := false
var _heat_shot := OS.get_cmdline_user_args().has("--heatmap")
var _pad_mode := false
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _last_paint := -1
var _test_seconds := 0.0
var _test_t := 0.0


func _ready() -> void:
	_build_environment()

	var tr := GameConfig.section("test_range")
	map = OutpostMap.new()
	map.name = "OutpostMap"
	add_child(map)
	map.generate_test_range(int(tr.get("width", 200)), int(tr.get("height", 140)), int(tr.get("seed", 1337)))

	fx = Fx.new()
	fx.name = "Fx"
	add_child(fx)
	fx.setup()

	structures = Structures.new()
	structures.name = "Structures"
	add_child(structures)
	structures.setup(map, fx)

	field = FlowField.new(map, "nav_cost")
	bfield = FlowField.new(map, "burrow_cost")
	field.build()
	bfield.build()
	print("[flowfield] %dx%d surface %.2f ms, burrow %.2f ms" % [map.w, map.h, field.build_usec / 1000.0, bfield.build_usec / 1000.0])
	structures.nav_changed.connect(_on_nav_changed)
	map.nav_changed.connect(_on_nav_changed)
	field.rebuilt.connect(_on_field_rebuilt)
	structures.core_destroyed.connect(_on_core_destroyed)

	swarm = Swarm.new()
	swarm.name = "Swarm"
	add_child(swarm)
	swarm.setup(map, field, bfield, GameConfig.alien_defs)

	corpses = Corpses.new()
	corpses.name = "Corpses"
	add_child(corpses)
	corpses.setup(map, swarm.pools, swarm.pools[0].instance.material_override)

	combat = Combat.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(swarm, map, structures, fx, corpses)

	cam = RTSCamera.new()
	cam.name = "CameraRig"
	add_child(cam)
	cam.position = map.core_center + Vector3(0, 0, -14)
	cam.bounds = Rect2(map.origin, Vector2(map.w, map.h))
	cam.distance = 55.0
	cam._target_distance = 55.0

	bench = BenchmarkRunner.new()
	bench.name = "Benchmark"
	bench.swarm = swarm
	bench.combat = combat
	bench.fx = fx
	add_child(bench)
	bench.finished.connect(_on_bench_finished)

	hud = Hud.new()
	hud.main = self
	add_child(hud)
	build = BuildBar.new()
	add_child(build)
	build.tool_changed.connect(func(_id): _last_paint = -1)

	_make_ghost()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	target_count = int(GameConfig.section("swarm").get("start_aliens", 1500))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--benchmark"):
			bench.quit_when_done = true
			var parts := arg.split("=")
			_start_benchmark(int(parts[1]) if parts.size() > 1 else -1)
		elif arg.begins_with("--aliens="):
			target_count = int(arg.split("=")[1])
		elif arg.begins_with("--combat-test"):
			var parts := arg.split("=")
			_test_seconds = float(parts[1]) if parts.size() > 1 else 40.0
		elif arg.begins_with("--screenshot="):
			_screenshot_after(arg.split("=")[1])


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.03, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.42, 0.5)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_hdr_threshold = 1.2
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


func _make_ghost() -> void:
	_ghost = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 1.0, 1.0)
	_ghost.mesh = bm
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost.material_override = _ghost_mat
	_ghost.visible = false
	add_child(_ghost)
	_ring = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0; cm.bottom_radius = 1.0; cm.height = 0.02; cm.radial_segments = 48; cm.rings = 0
	_ring.mesh = cm
	var rm := StandardMaterial3D.new()
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(0.3, 0.85, 1.0, 0.12)
	rm.no_depth_test = false
	_ring.material_override = rm
	_ring.visible = false
	add_child(_ring)


# ------------------------------------------------------------------ frame

func _process(delta: float) -> void:
	field.poll()
	bfield.poll()
	var dt := minf(delta, 1.0 / 30.0)
	_step(dt)
	_update_ghost()
	if _test_seconds > 0.0:
		_test_t += delta
		if _test_t >= _test_seconds:
			_print_test_report()
			get_tree().quit()


func _step(dt: float) -> void:
	swarm.simulate(dt)
	combat.process_swarm_events()
	combat.build_grid()
	if not swarm.paused:
		structures.tick(dt, combat)
		combat.tick_projectiles(dt)
	combat.flush_deaths()
	var want := bench.desired_population()
	if not overrun:
		swarm.approach_population(want if want >= 0 else target_count)
	swarm.upload()
	corpses.upload()
	fx.update(dt)


# ------------------------------------------------------------------ input

func _hover_cell() -> int:
	var pos := get_viewport().get_mouse_position()
	if _pad_mode:
		pos = get_viewport().get_visible_rect().size * 0.5
	var hit: Variant = cam.ground_point(pos)
	if hit == null:
		return -1
	return map.cell_of(hit)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if not _pad_mode:
			_pad_mode = true
			hud.set_crosshair(true)
	elif event is InputEventMouseMotion:
		if _pad_mode:
			_pad_mode = false
			hud.set_crosshair(false)

	if event.is_action_pressed("bench_run") and not bench.running():
		_start_benchmark(-1)
		return
	if bench.running():
		return
	for k in 8:
		if event.is_action_pressed("tool_%d" % (k + 1)):
			build.select_index(k)
			return
	if event.is_action_pressed("tool_next"):
		build.cycle(1)
	elif event.is_action_pressed("tool_prev"):
		build.cycle(-1)
	elif event.is_action_pressed("cancel"):
		build.select("")
	elif event.is_action_pressed("intel"):
		build.toggle_intel()
	elif event.is_action_pressed("primary"):
		_last_paint = -1
		_try_build()
	elif event.is_action_pressed("demolish"):
		structures.demolish(_hover_cell())
	elif event.is_action_pressed("bench_more"):
		target_count += 500
	elif event.is_action_pressed("bench_less"):
		target_count = maxi(0, target_count - 500)
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
		hud.detailed = not hud.detailed
	elif event.is_action_pressed("toggle_gore"):
		fx.gore = not fx.gore
	elif event.is_action_pressed("reset_walls"):
		reset_outpost()


func _try_build() -> void:
	var c := _hover_cell()
	if c < 0 or c == _last_paint or build.selected == "":
		return
	_last_paint = c
	structures.place(c, build.selected)


func _update_ghost() -> void:
	# drag-painting walls/doors, drag-demolish
	if not bench.running():
		if Input.is_action_pressed("primary") and build.selected in ["wall", "blast_door"]:
			_try_build()
		elif Input.is_action_pressed("demolish"):
			structures.demolish(_hover_cell())
	var c := _hover_cell()
	var show_range := 0.0
	if build.selected != "" and c >= 0:
		var ok := map.can_build(c)
		var d: Dictionary = structures.defs[build.selected]
		var hgt := float(d.get("height", 1.4))
		_ghost.visible = true
		_ghost.scale = Vector3(0.98, hgt, 0.98)
		_ghost.position = map.cell_center(c) + Vector3(0, hgt * 0.5, 0)
		_ghost_mat.albedo_color = Color(0.3, 1.0, 0.5, 0.35) if ok else Color(1.0, 0.25, 0.2, 0.35)
		show_range = float(d.get("range", 0.0))
	else:
		_ghost.visible = false
		if c >= 0 and structures.turrets.has(c):
			show_range = structures.turrets[c].range_m()
	_ring.visible = show_range > 0.0
	if _ring.visible:
		_ring.position = map.cell_center(c) + Vector3(0, 0.05, 0)
		_ring.scale = Vector3(show_range, 1.0, show_range)


# ------------------------------------------------------------------ events

func _on_nav_changed() -> void:
	field.request_rebuild()
	bfield.request_rebuild()
	structures._visual_dirty = true


func _on_field_rebuilt() -> void:
	if _heat_on:
		map.show_heatmap(field, true)


func _on_core_destroyed() -> void:
	overrun = true
	hud.show_banner("OUTPOST OVERRUN\nThe swarm has gutted the core.\nPress R to rebuild")


func reset_outpost() -> void:
	swarm.clear()
	corpses.clear()
	fx.clear()
	combat.reset_stats()
	structures.reset()
	overrun = false
	hud.show_banner("")


func _start_benchmark(n: int) -> void:
	structures.core_invulnerable = true
	swarm.recycle_at_core = true
	bench.start(n)


func _on_bench_finished(report: String) -> void:
	structures.core_invulnerable = false
	swarm.recycle_at_core = false
	hud.show_report(report)


# ------------------------------------------------------------------ dev

func _print_test_report() -> void:
	var lines := PackedStringArray(["=== combat test (%.0fs, pressure %d) ===" % [_test_seconds, target_count]])
	lines.append("alive %d  kills %d  dodges %d  corpses %d (charred %d)  climbable %d" % [swarm.total(), combat.kills, combat.dodges, corpses.count, corpses.charred_count, map.climbable_count()])
	var kb: PackedStringArray = []
	for p in swarm.pools:
		kb.append("%s %d" % [p.def.id, combat.kills_by_alien[p.type_id]])
	lines.append("kills by strain: " + ", ".join(kb))
	var tot := 0.0
	for v in combat.damage_by_type:
		tot += v
	var db: PackedStringArray = []
	for d in GameConfig.DMG_COUNT:
		db.append("%s %d%%" % [GameConfig.damage_type_ids[d], int(100.0 * combat.damage_by_type[d] / maxf(tot, 1.0))])
	lines.append("damage share: " + ", ".join(db))
	var tk: PackedStringArray = []
	for t: Turret in structures.turrets.values():
		tk.append("%s %d" % [t.def.id, t.kills])
	lines.append("turret kills: " + ", ".join(tk))
	lines.append("core %d/%d  structures lost %d  overrun %s" % [structures.core_hp, structures.core_max, structures.destroyed_count, overrun])
	lines.append("sim %.2f ms  combat %.2f ms  fx %.2f ms  fps %d" % [swarm.sim_usec / 1000.0, combat.combat_usec / 1000.0, fx.update_usec / 1000.0, Engine.get_frames_per_second()])
	print("\n".join(lines))


## Dev helper: `-- --aliens=N --screenshot=path.png [--cam=x,z,dist]`.
func _screenshot_after(path: String) -> void:
	var warm := 1800
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--warm="):
			warm = int(arg.split("=")[1])
	for k in warm:
		field.poll()
		bfield.poll()
		_step(1.0 / 60.0)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cam="):
			var v := arg.split("=")[1].split(",")
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
