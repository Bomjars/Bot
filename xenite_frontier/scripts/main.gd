extends Node3D
## M4 entry point: colony sandbox. Builds world, flow fields (surface,
## burrow, retreat-to-edge, hunt-colonists), swarm, combat, structures,
## corpses, economy, harvesters, colonists, fx, camera, HUD and build bar,
## then drives the frame:
##   poll fields -> swarm sim (threaded) -> swarm events (feeding) ->
##   colonist events (abductions) -> spatial grid -> turrets -> projectiles ->
##   drones -> colonists -> deaths/corpses -> spawning -> uploads.
##
## Command line (after `--`):
##   --benchmark[=N]   scripted benchmark with N aliens, then quit
##   --aliens=N        sandbox swarm pressure: N aliens spawned per minute
##   --combat-test[=S] headless combat soak for S seconds, prints stats, quits
##   --free-build      sandbox: building costs nothing (toggle in game: F11)
##   --screenshot=PATH dev: warm up, save a frame, quit (with --cam=x,z,dist)

var map: OutpostMap
var field: FlowField
var bfield: FlowField
var rfield: FlowField
var hfield: FlowField
var swarm: Swarm
var colonists: ColonistSystem
var waves: WaveDirector
var combat: Combat
var structures: Structures
var corpses: Corpses
var fx: Fx
var economy: Economy
var harvester: HarvesterSystem
var cam: RTSCamera
var hud: Hud
var build: BuildBar
var bench: BenchmarkRunner
## sandbox swarm pressure: aliens spawned per minute (ramps up at start)
var target_count := 240
var max_alive := 20000
var _spawn_acc := 0.0
var _unstick_timer := 0.0
var unstuck_total := 0
var overrun := false

var _heat_on := false
var _heat_shot := OS.get_cmdline_user_args().has("--heatmap")
var _pad_mode := false
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _last_paint := -1
var _selected := -1
var _insp_timer := 0.0
var _run_time := 0.0
var _ramp_seconds := 90.0
var _bot := false
var _bot_timer := 0.0
var _bot_plan: Array = []
var _bot_planned := false
var _test_seconds := 0.0
var _showcase_on := false
var _stuck_report := false
var _sandbox := false
var _auto_land := false
var _classic := false
var _drag_from := Vector2.ZERO
var _dragging_box := false
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
	fx.map = map
	map.terrain_material.set_shader_parameter("core_pos", map.core_center)

	economy = Economy.new()
	economy.name = "Economy"
	add_child(economy)
	economy.setup()

	structures = Structures.new()
	structures.name = "Structures"
	add_child(structures)
	structures.setup(map, fx, economy)

	field = FlowField.new(map, "nav_cost")
	bfield = FlowField.new(map, "burrow_cost")
	rfield = FlowField.new(map, "nav_cost", map.spawn_cells)
	hfield = FlowField.new(map, "nav_cost", PackedInt32Array([-1]))
	hfield.set_goals(PackedInt32Array())

	swarm = Swarm.new()
	swarm.name = "Swarm"
	add_child(swarm)
	swarm.setup(map, field, bfield, rfield, hfield, GameConfig.alien_defs)

	corpses = Corpses.new()
	corpses.name = "Corpses"
	add_child(corpses)
	corpses.setup(map, swarm.pools, swarm.pools[0].instance.material_override)

	harvester = HarvesterSystem.new()
	harvester.name = "Harvesters"
	add_child(harvester)
	harvester.setup(map, corpses, economy, fx)
	structures.built.connect(func(c, id): if id == "harvester_bay": harvester.add_bay(c, structures.tier_at(c), structures.center_of(c) + Vector3(-0.48, 0, 0.42)))
	structures.removed.connect(func(c, id):
		if id == "harvester_bay": harvester.remove_bay(c)
		if c == _selected: _select(-1))
	structures.upgraded.connect(func(c, id, t): if id == "harvester_bay": harvester.set_tier(c, t))
	economy.deposited.connect(func(amount, pos): fx.float_text(pos, "+%d" % int(round(amount)), Color(0.5, 1.0, 0.4)))

	colonists = ColonistSystem.new()
	colonists.name = "Colonists"
	add_child(colonists)
	colonists.setup(map, structures, corpses, fx, hfield, economy)
	structures.built.connect(colonists.on_structure_built)
	structures.site_placed.connect(colonists.on_structure_built)
	structures.removed.connect(colonists.on_structure_removed)
	colonists.event.connect(_on_colonist_event)

	structures.reset()
	colonists.reset()
	hfield.build()
	print("[flowfield] %dx%d surface %.2f ms, burrow %.2f ms" % [map.w, map.h, field.build_usec / 1000.0, bfield.build_usec / 1000.0])
	structures.nav_changed.connect(_on_nav_changed)
	map.nav_changed.connect(_on_nav_changed)
	field.rebuilt.connect(_on_field_rebuilt)
	structures.core_destroyed.connect(_on_core_destroyed)

	combat = Combat.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(swarm, map, structures, fx, corpses)
	combat.colonists = colonists
	colonists.combat = combat

	waves = WaveDirector.new()
	waves.name = "Waves"
	add_child(waves)
	waves.setup(swarm, economy, structures, colonists, map)
	waves.report.connect(func(text):
		hud.show_report_popup(text, 7.0 if text.begins_with("WAVE") and text.contains("SURVIVED") else 4.0)
		hud.log_event(text.split("\n")[0], Color(0.95, 0.85, 0.3)))

	cam = RTSCamera.new()
	cam.name = "CameraRig"
	add_child(cam)
	cam.position = map.core_center + Vector3(0, 0, -10)
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
	build.economy = economy
	build.structures = structures
	add_child(build)
	build.tool_changed.connect(func(id):
		_last_paint = -1
		map.set_grid_visible(id != "")
		if id != "": _select(-1))
	build.inspector_action.connect(_inspector_action)

	_make_ghost()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	target_count = int(GameConfig.section("swarm").get("spawn_per_minute", 240))
	max_alive = int(GameConfig.section("swarm").get("max_alive", 20000))
	_ramp_seconds = float(GameConfig.section("swarm").get("ramp_seconds", 90.0))
	var args := OS.get_cmdline_user_args()
	var bench_n := -2
	for arg in args:
		if arg.begins_with("--benchmark"):
			bench.quit_when_done = true
			var parts := arg.split("=")
			bench_n = int(parts[1]) if parts.size() > 1 else -1
			_auto_land = true
			_classic = true
		elif arg.begins_with("--aliens="):
			target_count = int(arg.split("=")[1])
		elif arg == "--bot":
			_bot = true
			_auto_land = true
			_classic = true
		elif arg == "--sandbox":
			_sandbox = true
			_auto_land = true
			_classic = true
		elif arg == "--fast-waves":
			GameConfig.waves["first_build_seconds"] = 15
			GameConfig.waves["build_seconds"] = 8
		elif arg == "--auto-land":
			_auto_land = true
		elif arg == "--classic":
			_auto_land = true
			_classic = true
		elif arg == "--free-build":
			economy.free_build = true
		elif arg.begins_with("--strain="):
			swarm.only_strain(maxi(0, GameConfig.alien_index(arg.split("=")[1])))
			waves.dev_strain = maxi(0, GameConfig.alien_index(arg.split("=")[1]))
		elif arg.begins_with("--start-wave="):
			waves.start_wave = maxi(0, int(arg.split("=")[1]) - 1)
		elif arg == "--stuck-report":
			_stuck_report = true
		elif arg.begins_with("--combat-test"):
			var parts := arg.split("=")
			_test_seconds = float(parts[1]) if parts.size() > 1 else 40.0
			_auto_land = true
		elif arg == "--showcase":
			_auto_land = true
			_classic = false
			_showcase.call_deferred()
		elif arg == "--buildings":
			_auto_land = true
			_classic = false
			_building_showcase.call_deferred()
		elif arg.begins_with("--screenshot="):
			_auto_land = true
	if _auto_land:
		land(map.default_site, _classic)
	else:
		_begin_landing()
	if bench_n != -2:
		_start_benchmark(bench_n)
	for arg in args:
		if arg.begins_with("--screenshot="):
			_screenshot_after(arg.split("=")[1])


# ------------------------------------------------------------------ run flow

func _begin_landing() -> void:
	waves.reset()
	hud.show_banner("")
	hud.show_report_popup("CHOOSE YOUR LANDING SITE\nClick open, flat ground away from the canyon mouths.\nThe Command Hab lands there; build your outpost around it.", 9.0)
	cam.position = map.core_center
	cam._target_distance = 95.0


## Founds the outpost at `cell` and starts the build phase.
func land(cell: Vector2i, classic := false) -> void:
	map.set_base(cell)
	if classic:
		map.classic_layout()
	else:
		map.initial_structures.clear()
	field.set_goals(map.goal_cells)
	bfield.set_goals(map.goal_cells)
	structures.instant_build = true
	structures.reset()
	structures.instant_build = false
	field.build()
	bfield.build()
	rfield.build()
	colonists.reset()
	colonists.spawn_starting_crew()
	waves.reset()
	if not _sandbox:
		waves.begin_after_landing()
	else:
		waves.phase = WaveDirector.Phase.BUILD
		waves.timer = 1e9
	cam.position = map.core_center + Vector3(0, 0, -6)
	cam._target_distance = 55.0
	_run_time = 0.0
	map.show_heatmap(field, _heat_on)


func call_wave_early() -> void:
	waves.call_early()


func _build_environment() -> void:
	# dim violet sky with a ringed gas giant and a small moon
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = preload("res://scripts/render/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.65
	env.ambient_light_color = Color(0.5, 0.4, 0.58)
	env.ambient_light_energy = 1.15
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_hdr_threshold = 1.1
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.36, 0.22, 0.3)
	env.fog_density = 0.0035
	env.fog_sky_affect = 0.4
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.05
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.86, 0.74)
	sun.light_energy = 1.1
	sun.rotation_degrees = Vector3(-33, -40, 0)   # low sun: relief casts shadows
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 140.0
	add_child(sun)
	# cool bounce from the opposite side so shadowed cliffs read
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.55, 0.42, 0.85)
	fill.light_energy = 0.55
	fill.rotation_degrees = Vector3(-30, 150, 0)
	add_child(fill)


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
	_poll_fields()
	var dt := minf(delta, 1.0 / 30.0)
	_step(dt)
	_update_ghost()
	swarm.set_far_lod(cam.distance > 62.0)
	_insp_timer -= delta
	if _insp_timer <= 0.0:
		_insp_timer = 0.25
		build.refresh_affordability()
		if _selected >= 0:
			build.show_inspector(_inspector_info(_selected))
	if _test_seconds > 0.0:
		_test_t += delta
		if _test_t >= _test_seconds:
			_print_test_report()
			if _stuck_report:
				_print_stuck_report()
			get_tree().quit()


func _poll_fields() -> void:
	field.poll()
	bfield.poll()
	rfield.poll()
	hfield.poll()


func _step(dt: float) -> void:
	swarm.listen = Vector2(cam.position.x, cam.position.z)
	swarm.simulate(dt)
	combat.build_grid()
	combat.process_swarm_events()
	colonists.process_swarm(swarm, combat)
	combat.behaviour_fx(dt)
	_shake_from(combat.shake_events)
	if not swarm.paused:
		structures.tick(dt, combat)
		combat.tick_projectiles(dt)
		harvester.tick(dt)
		colonists.tick(dt)
		_unstick_timer -= dt
		if _unstick_timer <= 0.0:
			_unstick_timer = 1.0
			unstuck_total += combat.unstick()
	combat.flush_deaths()
	_run_time += dt
	var want := bench.desired_population()
	if want >= 0:
		# benchmark: hold a fixed population
		swarm.approach_population(want)
	elif not overrun and not swarm.paused and not _sandbox:
		waves.tick(dt)
	elif not overrun and not swarm.paused:
		# sandbox: spawn at a rate (aliens per minute) that ramps up over the
		# first 90 s. Killing fast genuinely thins the swarm.
		var ramp := clampf(_run_time / maxf(_ramp_seconds, 0.01), 0.1, 1.0)
		_spawn_acc += target_count / 60.0 * ramp * dt
		var n := int(_spawn_acc)
		if n > 0:
			_spawn_acc -= n
			swarm.spawn_random(mini(n, maxi(0, max_alive - swarm.total())))
	if _bot:
		_bot_tick(dt)
	if OS.get_cmdline_user_args().has("--mode-trace") and int(_run_time * 60.0) % 300 == 0:
		for p in swarm.pools:
			if p.count == 0:
				continue
			var modes := {}
			var tg := 0
			var dsum := 0
			for i in p.count:
				modes[p.mode[i]] = modes.get(p.mode[i], 0) + 1
				if p.tgt[i] >= 0:
					tg += 1
				var c := map.cell_of(Vector3(p.px[i], 0, p.pz[i]))
				dsum += field.dist[c] if c >= 0 else 0
			print("[dbg %.0fs] %s n=%d modes=%s tgt=%d avg_dist=%.1fm val0=%.1f" % [_run_time, p.def.id, p.count, modes, tg, dsum / 10.0 / p.count, p.val[0]])
	swarm.upload()
	corpses.upload()
	fx.update(dt)


## Heavy footfalls, charge impacts, roars and breaches near the view shake
## the camera (falls off over ~30 m from the point the camera looks at).
func _shake_from(ev: PackedFloat32Array) -> void:
	if ev.is_empty() or cam == null:
		return
	var total := 0.0
	for k in range(0, ev.size(), 3):
		var d := Vector2(ev[k] - cam.position.x, ev[k + 1] - cam.position.z).length()
		total += ev[k + 2] * clampf(1.0 - d / 30.0, 0.0, 1.0)
	if total > 0.0:
		cam.add_shake(minf(0.5, total * 0.12))


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

	if waves.phase == WaveDirector.Phase.LANDING:
		if event.is_action_pressed("primary"):
			var c := _hover_cell()
			if c >= 0:
				var v := Vector2i(c % map.w, c / map.w)
				var why := map.landing_problem(v)
				if why == "":
					land(v)
				else:
					build.toast(why)
		return
	if event.is_action_pressed("bench_run") and not bench.running():
		_start_benchmark(-1)
		return
	if bench.running():
		return
	if event.is_action_pressed("call_wave"):
		call_wave_early()
		return
	if event.is_action_pressed("category_next"):
		build.next_category()
		return
	if event.is_action_pressed("release_squad"):
		colonists.release_orders(colonists.selected_count() == 0)
		return
	if event.is_action_released("primary") and build.selected == "" and not _pad_mode:
		_finish_click_or_box(event)
		return
	for k in 10:
		if event.is_action_pressed("tool_%d" % (k + 1)):
			build.select_index(k)
			return
	if event.is_action_pressed("tool_next"):
		build.cycle(1)
	elif event.is_action_pressed("tool_prev"):
		build.cycle(-1)
	elif event.is_action_pressed("cancel"):
		build.select("")
		_select(-1)
	elif event.is_action_pressed("intel"):
		build.toggle_intel()
	elif event.is_action_pressed("primary"):
		_last_paint = -1
		if build.selected != "":
			_try_build(true)
		elif _pad_mode:
			_click_select(false)
		else:
			_drag_from = get_viewport().get_mouse_position()
			_dragging_box = true
	elif event.is_action_pressed("demolish"):
		if build.selected == "" and colonists.selected_count() > 0:
			var hit: Variant = cam.ground_point(_cursor_pos())
			if hit != null:
				var n := colonists.order_move(hit)
				fx.float_text(hit + Vector3(0, 1.5, 0), "MOVE (%d)" % n, Color(0.4, 1.0, 0.5))
		elif build.selected == "" and _selected != -1 and not _pad_mode and structures.anchor_of(_hover_cell()) != _selected:
			_select(-1)
		else:
			structures.sell(_hover_cell())
	elif event.is_action_pressed("upgrade"):
		_inspector_action("upgrade")
	elif event.is_action_pressed("repair"):
		_inspector_action("repair")
	elif event.is_action_pressed("free_build"):
		economy.free_build = not economy.free_build
		build.toast("Sandbox free build: %s" % ("ON" if economy.free_build else "OFF"))
	elif event.is_action_pressed("bench_more"):
		target_count += 60
	elif event.is_action_pressed("bench_less"):
		target_count = maxi(0, target_count - 60)
	elif event.is_action_pressed("bench_preset_1"):
		target_count = 120
	elif event.is_action_pressed("bench_preset_2"):
		target_count = 600
	elif event.is_action_pressed("bench_preset_3"):
		target_count = 3000
	elif event.is_action_pressed("bench_preset_4"):
		target_count = 12000
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


func _cursor_pos() -> Vector2:
	if _pad_mode:
		return get_viewport().get_visible_rect().size * 0.5
	return get_viewport().get_mouse_position()


## LMB released with no build tool: a click selects a soldier / structure /
## the Command Hab; a drag selects every soldier in the box.
func _finish_click_or_box(event: InputEvent) -> void:
	if not _dragging_box:
		return
	_dragging_box = false
	hud.set_drag_rect(Rect2())
	var to := get_viewport().get_mouse_position()
	var additive := Input.is_key_pressed(KEY_SHIFT)
	if _drag_from.distance_to(to) > 10.0:
		if not additive:
			colonists.select_none()
		colonists.select_in_rect(Rect2(_drag_from, to - _drag_from).abs(), cam.camera)
		if colonists.selected_count() > 0:
			_select(-1)
		return
	_click_select(additive)


func _click_select(additive: bool) -> void:
	var hit: Variant = cam.ground_point(_cursor_pos())
	if hit != null:
		var sol := colonists.soldier_at(hit)
		if sol:
			if not additive:
				colonists.select_none()
			colonists.set_selected(sol, not sol.selected if additive else true)
			_select(-1)
			return
	colonists.select_none()
	var c := _hover_cell()
	if c >= 0 and map.is_core(c):
		_select(-2)
	else:
		_select(structures.anchor_of(c) if c >= 0 else -1)


func _try_build(report := false) -> void:
	var c := _hover_cell()
	if c < 0 or c == _last_paint or build.selected == "":
		return
	_last_paint = c
	var err := structures.try_build(c, build.selected)
	if err != "" and report:
		build.toast(err)


func _select(c: int) -> void:
	_selected = c
	_insp_timer = 0.0
	build.show_inspector(_inspector_info(c) if c >= 0 else {})


func _inspector_action(action: String) -> void:
	if _selected == -1:
		return
	var err := ""
	match action:
		"recruit_worker": err = colonists.recruit(ColonistSystem.Role.WORKER)
		"train_soldier": err = colonists.recruit(ColonistSystem.Role.SOLDIER)
		"upgrade": err = structures.upgrade(_selected)
		"repair": err = structures.repair(_selected)
		"sell":
			structures.sell(_selected)
			_select(-1)
			return
	if err != "":
		build.toast(err)
	_select(_selected)


## Text + buttons for the Inspector panel.
func _inspector_info(c: int) -> Dictionary:
	if c == -2:
		var rc: Dictionary = GameConfig.econ("recruit").get("worker", {})
		var t := "[b]Command Hab[/b]\nHP %d / %d\nColonists %d / %d   workers %d   soldiers %d\nWages %d Biomass per wave%s" % [
			int(structures.core_hp), int(structures.core_max), colonists.alive(), colonists.pop_cap(),
			colonists.count_role(ColonistSystem.Role.WORKER), colonists.count_role(ColonistSystem.Role.SOLDIER), colonists.wages_due(),
			("\nTraining: %d" % colonists.training.size()) if not colonists.training.is_empty() else ""]
		return {"text": t, "buttons": [{"label": "Recruit worker  %d" % int(rc.get("cost", 40)), "action": "recruit_worker", "enabled": economy.can_afford(int(rc.get("cost", 40)))}]}
	if not structures.ids.has(c):
		return {}
	var id: String = structures.ids[c]
	var d: Dictionary = structures.defs[id]
	var tier := structures.tier_at(c)
	var tname: String = GameConfig.tiers[clampi(tier - 1, 0, GameConfig.tiers.size() - 1)].get("name", str(tier))
	var lines: PackedStringArray = []
	var buttons: Array = []
	var maxt := GameConfig.max_tier(id)
	var head := "[b]%s[/b]" % d.name
	if maxt > 1 and not structures.is_site(c):
		head += "   Tier %s" % tname
	if d.has("damage_type"):
		var di := GameConfig.damage_index(d.damage_type)
		head += "   [color=#%s]%s[/color]" % [GameConfig.damage_color(di).to_html(false), GameConfig.damage_name(di)]
	lines.append(head)
	lines.append("HP %d / %d" % [int(map.shp[c]), int(map.smax[c])])
	if structures.is_site(c):
		var builders := colonists.names_at(c, ColonistSystem.Job.BUILD)
		lines.append("[color=#ffd21a]UNDER CONSTRUCTION  %d%%[/color]" % int(structures.site_progress(c) * 100))
		lines.append(("Builders: " + ", ".join(builders)) if not builders.is_empty() else "[color=#ff7a6a]Waiting for a free worker[/color]")
		buttons.append({"label": "Cancel  +%d" % structures.sell_value(c), "action": "sell"})
		return {"text": "\n".join(lines), "buttons": buttons}
	var up := structures.upgrade_cost(c)
	if structures.turrets.has(c):
		var t: Turret = structures.turrets[c]
		lines.append("Damage %.0f   Range %.1fm   Fire %.2f/s   Crew eff. %d%%" % [t.dmg, t.rng, t.fire_rate(), roundi(t.crew_efficiency * 100)])
		if up >= 0:
			var nt: Dictionary = GameConfig.tiers[tier]
			lines.append("[color=#9fd]Next: damage %.0f, range %.1fm, crew eff. %d%%[/color]" % [float(d.damage) * float(nt.damage), float(d.range) * float(nt.range), roundi(float(nt.crew_efficiency) * 100)])
		elif tier >= maxt:
			lines.append("[color=#aaa]Specialisation at tier III: unlock in the Colony Charter (M6)[/color]")
		var crew := colonists.crew_name(c)
		if t.crewed:
			lines.append("Crew: %s" % crew)
		else:
			lines.append("[color=#ff7a6a]UNCREWED - firing at %d%%[/color]%s" % [roundi(colonists.uncrewed_rate * 100), ("   (%s)" % crew) if crew != "" else ""])
		lines.append("Kills: %d" % t.kills)
	elif id == "harvester_bay":
		var drones := 0
		var cargo := 0.0
		if harvester.bays.has(c):
			drones = harvester.bays[c].drones.size()
			for dr in harvester.bays[c].drones:
				cargo += dr.cargo
		lines.append("Drones %d   range %.0fm   carrying %d" % [drones, harvester.bay_range(tier), int(cargo)])
		if up >= 0:
			lines.append("[color=#9fd]Next: %d drones, range %.0fm[/color]" % [int(harvester.drones_per_tier[tier]), harvester.bay_range(tier + 1)])
	elif id == "floodlight":
		lines.append("Light radius %.0fm   (turrets need light at night - M5b)" % structures.light_radius())
	elif id == "guard_post":
		var g := colonists.names_at(c, ColonistSystem.Job.GARRISON)
		lines.append("Garrison %d/%d: %s" % [g.size(), int(d.get("garrison", 2)), ", ".join(g) if not g.is_empty() else "none - train soldiers at a Barracks"])
	elif id == "barracks":
		var rc: Dictionary = GameConfig.econ("recruit").get("soldier", {})
		lines.append("Soldiers %d   colonists %d/%d" % [colonists.count_role(ColonistSystem.Role.SOLDIER), colonists.alive(), colonists.pop_cap()])
		buttons.append({"label": "Train soldier  %d" % int(rc.get("cost", 60)), "action": "train_soldier", "enabled": economy.can_afford(int(rc.get("cost", 60)))})
	elif id == "hab_module":
		lines.append("+%d colonist capacity   (now %d/%d)" % [int(d.get("pop_cap", 4)), colonists.alive(), colonists.pop_cap()])
	elif map.climb[c]:
		lines.append("[color=#bf8]Corpse pile alongside: the swarm can climb this![/color]")
	if not structures.turrets.has(c) and id not in ["harvester_bay", "wall", "blast_door"]:
		lines.append(d.get("role", ""))
	if int(d.get("staff", 0)) > 0:
		var st := colonists.names_at(c, ColonistSystem.Job.STAFF)
		lines.append(("Staff: " + ", ".join(st)) if not st.is_empty() else "[color=#ff7a6a]UNSTAFFED - inactive (needs a free worker)[/color]")
	if id == "mining_rig":
		lines.append("Mining %d Xenite/min while staffed" % int(d.get("xenite_per_minute", 14)))
	var rc2 := structures.repair_cost(c)
	if up >= 0:
		var blk := structures.upgrade_block(c)
		buttons.append({"label": ("Upgrade [U]  %d" % up) if blk == "" else blk, "action": "upgrade", "enabled": blk == "" and economy.can_afford(up)})
	if rc2 > 0:
		buttons.append({"label": "Repair [R]  %d" % rc2, "action": "repair", "enabled": economy.can_afford(rc2)})
	buttons.append({"label": "Sell  +%d" % structures.sell_value(c), "action": "sell"})
	return {"text": "\n".join(lines), "buttons": buttons}


func _update_ghost() -> void:
	if waves.phase == WaveDirector.Phase.LANDING:
		var c0 := _hover_cell()
		_ring.visible = false
		if c0 < 0:
			_ghost.visible = false
			return
		var v := Vector2i(c0 % map.w, c0 / map.w)
		var ok := map.landing_problem(v) == ""
		_ghost.visible = true
		_ghost.scale = Vector3(7.0, 0.4, 7.0)
		_ghost.position = map.cell_ground(c0) + Vector3(0, 0.2, 0)
		_ghost_mat.albedo_color = Color(0.3, 1.0, 0.5, 0.35) if ok else Color(1.0, 0.25, 0.2, 0.35)
		return
	if _dragging_box and Input.is_action_pressed("primary"):
		var to := get_viewport().get_mouse_position()
		if _drag_from.distance_to(to) > 10.0:
			hud.set_drag_rect(Rect2(_drag_from, to - _drag_from).abs())
	# drag-painting walls/doors, drag-demolish
	if not bench.running():
		if Input.is_action_pressed("primary") and build.selected in ["wall", "blast_door"]:
			_try_build()
		elif Input.is_action_pressed("demolish") and build.selected != "":
			structures.sell(_hover_cell())
	var c := _hover_cell()
	var show_range := 0.0
	if build.selected != "" and c >= 0:
		var ok := structures.can_place(c, build.selected) and economy.can_afford(structures.cost_of(build.selected))
		if structures.defs[build.selected].get("needs_deposit", false):
			ok = ok and structures.on_deposit(c, build.selected)
		var d: Dictionary = structures.defs[build.selected]
		var hgt := float(d.get("height", 1.4))
		var fp := structures.footprint(build.selected)
		_ghost.visible = true
		_ghost.scale = Vector3(fp - 0.02, hgt, fp - 0.02)
		_ghost.position = map.cell_ground(c) + Vector3((fp - 1) * 0.5, hgt * 0.5, (fp - 1) * 0.5)
		_ghost_mat.albedo_color = Color(0.3, 1.0, 0.5, 0.35) if ok else Color(1.0, 0.25, 0.2, 0.35)
		show_range = _range_of(build.selected, 1, -1)
	else:
		_ghost.visible = false
		if _selected == -2:
			c = -1
		elif _selected >= 0:
			c = _selected
			show_range = _range_of(structures.id_at(c), structures.tier_at(c), c)
		elif c >= 0 and structures.anchor_of(c) >= 0:
			c = structures.anchor_of(c)
			show_range = _range_of(structures.id_at(c), structures.tier_at(c), c)
	_ring.visible = show_range > 0.0
	if _ring.visible:
		_ring.position = (structures.center_of(c) if structures.ids.has(c) else map.cell_ground(c)) + Vector3(0, 0.08, 0)
		_ring.scale = Vector3(show_range, 1.0, show_range)


func _range_of(id: String, tier: int, c: int) -> float:
	if c >= 0 and structures.turrets.has(c):
		return structures.turrets[c].range_m()
	match id:
		"harvester_bay": return harvester.bay_range(tier)
		"floodlight": return structures.light_radius()
	return float(structures.defs.get(id, {}).get("range", 0.0))


# ------------------------------------------------------------------ events

func _on_nav_changed() -> void:
	field.request_rebuild()
	bfield.request_rebuild()
	rfield.request_rebuild()
	structures._visual_dirty = true


func _on_field_rebuilt() -> void:
	if _heat_on:
		map.show_heatmap(field, true)


func _on_colonist_event(text: String, col: Color, pos: Vector3) -> void:
	hud.log_event(text, col)
	fx.float_text(pos + Vector3(0, 2.0, 0), "!", col)


func _on_core_destroyed() -> void:
	overrun = true
	hud.show_banner("OUTPOST OVERRUN - wave %d\nThe swarm has gutted the Command Hab.\nPress F10 for a new run" % waves.wave)
	waves.phase = WaveDirector.Phase.OVER


func reset_outpost() -> void:
	_select(-1)
	colonists.select_none()
	swarm.clear()
	harvester.clear()
	corpses.clear()
	fx.clear()
	combat.reset_stats()
	economy.reset()
	overrun = false
	hud.show_banner("")
	if _auto_land:
		land(map.default_site, _classic)
	else:
		map.initial_structures.clear()
		structures.reset()
		colonists.reset()
		_begin_landing()
	_run_time = 0.0
	_spawn_acc = 0.0
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

## Scripted player for soak tests (`--bot`): spends Biomass on a fixed build
## order, then upgrades and repairs, exercising the whole economy loop.
func _bot_tick(dt: float) -> void:
	_bot_timer -= dt
	if _bot_timer > 0.0:
		return
	_bot_timer = 1.0
	var core := map.world_to_cell(map.core_center)
	if not _bot_planned:
		_bot_planned = true
		# seal three airlocks with walls (the swarm will bash or reroute),
		# keep every turret inside: the north airlock becomes the kill zone
		_bot_plan = []
		for o in range(-2, 3):
			_bot_plan.append([o, 9, "wall"])
			_bot_plan.append([-13, o, "wall"])
			_bot_plan.append([13, o, "wall"])
		_bot_plan.append_array([
			[-2, -7, "shock_grid"], [2, -5, "seismic_spike"], [0, -3, "railgun"],
			[-9, 2, "barracks"], [-5, -8, "guard_post"], [5, -8, "guard_post"],
			[-5, -2, "harvester_bay"], [10, -5, "bio_refinery"], [-9, 5, "hab_module"],
			[3, -8, "shock_grid"], [-10, 0, "mortar"], [-11, 5, "armory"],
			[8, -2, "autocannon"], [-2, -3, "flamethrower"], [10, 0, "railgun"],
		])
		# a Mining Rig on the deposit nearest the outpost
		var best_d := INF
		var best_dc := Vector2i(-1, -1)
		for dc in map.deposit_centers:
			var dd := Vector2(dc).distance_to(Vector2(core))
			if dd < best_d:
				best_d = dd
				best_dc = dc
		if best_dc.x >= 0:
			_bot_plan.insert(9, [best_dc.x - core.x, best_dc.y - core.y, "mining_rig"])
	# build next planned item if affordable
	if not _bot_plan.is_empty():
		var e: Array = _bot_plan[0]
		var c := map.idx(core.x + e[0], core.y + e[1])
		if not structures.can_place(c, e[2]):
			_bot_plan.pop_front()
		elif economy.can_afford(GameConfig.build_cost(e[2])):
			structures.try_build(c, e[2])
			_bot_plan.pop_front()
		return
	# keep the garrisons topped up
	if structures.count_built("barracks") > 0 and economy.biomass > 160 and colonists.alive() + colonists.training.size() < colonists.pop_cap():
		colonists.recruit(ColonistSystem.Role.SOLDIER)
		return
	# then repair the most damaged, then upgrade the cheapest
	for c: int in structures.ids:
		if structures.repair_cost(c) > 25 and economy.can_afford(structures.repair_cost(c)):
			structures.repair(c)
			return
	var best := -1
	var best_cost := 1 << 30
	for c: int in structures.ids:
		var u := structures.upgrade_cost(c)
		if u >= 0 and u < best_cost:
			best_cost = u
			best = c
	if best >= 0 and economy.can_afford(best_cost):
		structures.upgrade(best)


func _print_test_report() -> void:
	var lines := PackedStringArray(["=== combat test (%.0fs, pressure %d aliens/min) ===" % [_test_seconds, target_count]])
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
	var tiers_txt: PackedStringArray = []
	for c: int in structures.ids:
		if structures.tier_at(c) > 1:
			tiers_txt.append("%s T%d" % [structures.ids[c], structures.tier_at(c)])
	lines.append("upgraded: " + (", ".join(tiers_txt) if not tiers_txt.is_empty() else "none"))
	lines.append("core %d/%d  structures lost %d  overrun %s" % [structures.core_hp, structures.core_max, structures.destroyed_count, overrun])
	lines.append("biomass %d  collected %d  spent %d  drone trips %d  corpses harvested %d  value lost to decay %d  still on field %d  drones %d" % [
		economy.biomass, economy.collected, economy.spent, harvester.trips, corpses.harvested, corpses.biomass_lost, corpses.harvestable_value(), harvester.drone_count()])
	lines.append("wave %d (phase %d)  threat x%.2f  bounties %d  ore sales %d  wages %d  xenite banked %d  morale low %s" % [
		waves.wave, waves.phase, waves.threat, economy.bounties, economy.ore_sales, economy.wages_paid, waves.xenite_banked, waves.morale_low])
	lines.append("colonists alive %d/%d (cap %d)  workers %d  soldiers %d  recruited %d  abductions %d  rescued %d  taken %d  mauled %d" % [
		colonists.alive(), colonists.colonists.size(), colonists.pop_cap(), colonists.count_role(ColonistSystem.Role.WORKER), colonists.count_role(ColonistSystem.Role.SOLDIER),
		colonists.recruited, colonists.abductions, colonists.rescued, colonists.taken, colonists.killed])
	var built_txt: PackedStringArray = []
	for bid in ["guard_post", "mining_rig", "hab_module", "barracks", "bio_refinery", "fabricator", "armory", "medbay"]:
		if structures.count_built(bid) > 0:
			built_txt.append("%s %d/%d active" % [bid, structures.count_active(bid), structures.count_built(bid)])
	lines.append("buildings: " + (", ".join(built_txt) if not built_txt.is_empty() else "none") + "   sites open %d" % structures.sites.size())
	var crewed := 0
	for t: Turret in structures.turrets.values():
		if t.crewed:
			crewed += 1
	lines.append("v4 behaviour: spitter shots %d  burrower breaches %d  mauler charges landed %d (on blast doors %d)  elder roars %d" % [combat.spits, combat.breaches, combat.charges_landed, combat.charges_on_doors, combat.roars])
	lines.append("turrets crewed %d/%d  meals %d (human %d)  biggest alien x%.2f  remains on field %d" % [crewed, structures.turrets.size(), combat.meals, corpses.humans_eaten, combat.biggest, corpses.human_remains()])
	lines.append("sim %.2f ms  combat %.2f ms  fx %.2f ms  fps %d" % [swarm.sim_usec / 1000.0, combat.combat_usec / 1000.0, fx.update_usec / 1000.0, Engine.get_frames_per_second()])
	print("\n".join(lines))


## Diagnostics: where are aliens stuck (not moving >4 s with no reason)?
func _print_stuck_report() -> void:
	var by_cell := {}
	var total := 0
	var alive := 0
	var reasons := {}
	for p in swarm.pools:
		for i in p.count:
			alive += 1
			if p.stuck[i] < 4.0:
				continue
			total += 1
			var c := map.cell_of(Vector3(p.px[i], 0, p.pz[i]))
			if not by_cell.has(c):
				by_cell[c] = {}
			var key: String = p.def.id + ("(burrowed)" if p.aux[i] > 0.5 else "") + ("(carrying)" if p.carry[i] >= 0 else "")
			by_cell[c][key] = by_cell[c].get(key, 0) + 1
			var why := _stuck_reason(c, p, i)
			reasons[why] = reasons.get(why, 0) + 1
	print("=== stuck report: %d of %d aliens stuck >4s  (safety net moved/removed %d during the run) ===" % [total, alive, unstuck_total])
	for r in reasons:
		print("  reason %-34s %d" % [r, reasons[r]])
	var cells := by_cell.keys()
	cells.sort_custom(func(a, b):
		var na := 0
		var nb := 0
		for v in by_cell[a].values(): na += v
		for v in by_cell[b].values(): nb += v
		return na > nb)
	for k in mini(8, cells.size()):
		var c: int = cells[k]
		var wp := map.cell_center(c)
		print("cell %d (grid %d,%d world %.0f,%.0f) kind %d dist %d dir (%.2f,%.2f) pile %.2f  %s" % [c, c % map.w, c / map.w, wp.x, wp.z, map.kind[c], field.dist[c], field.dir_x[c], field.dir_z[c], map.pile[c], str(by_cell[c])])
		var rows: PackedStringArray = []
		for oz in range(-3, 4):
			var row := ""
			for ox in range(-3, 4):
				var x := (c % map.w) + ox
				var z := (c / map.w) + oz
				if not map.in_bounds(x, z):
					row += " "
					continue
				var cc := map.idx(x, z)
				var ch := "."
				if map.kind[cc] == OutpostMap.Kind.ROCK: ch = "#"
				elif map.kind[cc] == OutpostMap.Kind.STRUCT: ch = "W" if map.climb[cc] == 0 else "w"
				elif map.is_goal(cc): ch = "C"
				if ox == 0 and oz == 0: ch = "@"
				row += ch
			rows.append("    " + row)
		print("\n".join(rows))


func _stuck_reason(c: int, p: AlienPool, i: int) -> String:
	if c < 0:
		return "off-grid"
	var burrowed := p.aux[i] > 0.5
	var f := bfield if burrowed else (rfield if p.carry[i] >= 0 else field)
	if f.dist[c] >= FlowField.UNREACHABLE:
		return "unreachable cell (no path)"
	if f.dir_x[c] == 0.0 and f.dir_z[c] == 0.0:
		return "zero direction"
	if map.kind[c] != OutpostMap.Kind.GROUND:
		return "inside rock/structure"
	var ax := int(p.px[i] - map.origin.x + f.dir_x[c] * 0.8)
	var az := int(p.pz[i] - map.origin.y + f.dir_z[c] * 0.8)
	var ac := map.idx(ax, az)
	if map.kind[ac] == OutpostMap.Kind.ROCK:
		return "flow points into rock"
	if map.kind[ac] == OutpostMap.Kind.STRUCT:
		return "pressing structure (no bash)"
	return "crowd / other"


## Dev: line up every strain on the pad in four poses (idle, walk, sprint on
## all fours, attack) facing the camera, plus a feeding one. `-- --showcase`
func _showcase() -> void:
	target_count = 0
	swarm.paused = true
	var row := map.core_center + Vector3(-12.0, 0, -18.0)
	for t in swarm.pools.size():
		var p := swarm.pools[t]
		var x := row.x + t * 3.4
		# idle, run, attack, then the strain's v4 tell / action
		var special := {"spitter": -4.7, "burrower": -4.7, "mauler": -6.4, "elder": -4.7, "snatcher": -6.4, "runt": -2.0}
		var poses := [0.35, 1.0, -2.0, float(special.get(p.def.id, -1.0))]
		for k in poses.size():
			var z := row.z + k * 2.6
			var i := p.spawn(x, z, swarm.rng)
			var o := i * AlienPool.STRIDE
			p.buf[o] = 1.0; p.buf[o + 2] = 0.0; p.buf[o + 8] = 0.0; p.buf[o + 10] = 1.0
			p.buf[o + 5] = 1.0
			p.buf[o + 7] = map.height_at(x, z)
			p.buf[o + 14] = 0.8 + k * 1.7
			p.buf[o + 15] = poses[k]
			p.buf[o + 13] = -1.0 if p.young_max > 0 else 0.0
			p.buf[o] = p.size[i]; p.buf[o + 5] = p.size[i]; p.buf[o + 10] = p.size[i]
		# a corpse of each strain in the front row (its death pose)
		corpses.add(t, x, row.z + 4 * 2.6 + 0.3, PI * 0.15, 1.0, 0.1, false)
	corpses.upload()
	# photo mode: no UI, close low camera (pick the strain pair with --pair=N)
	hud.visible = false
	build.visible = false
	var pair := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pair="):
			pair = int(arg.split("=")[1])
	cam.position = row + Vector3(1.7 + pair * 6.8, 1.0, 7.5)
	cam.pitch_deg = 24.0
	cam.photo_lock = true
	cam._target_distance = 9.0
	cam.distance = 9.0


## Dev: every building of the concept sheet in rows next to the Command Hab,
## plus a construction site. `-- --buildings --screenshot=x.png`
func _building_showcase() -> void:
	target_count = 0
	swarm.paused = true
	var cc := map.world_to_cell(map.core_center)
	var rows := [["wall", "wall", "blast_door", "wall", "floodlight", "guard_post"],
		["harvester_bay", "mining_rig", "hab_module", "barracks"],
		["bio_refinery", "fabricator", "armory", "medbay", "site:barracks"]]
	for r in rows.size():
		var x := cc.x - 7
		for id: String in rows[r]:
			var site := id.begins_with("site:")
			var bid := id.substr(5) if site else id
			var fp := structures.footprint(bid)
			var c := map.idx(x, cc.y + 3 + r * 3)
			if site:
				structures._place_site(c, bid)
			else:
				structures.place(c, bid, false)
			x += fp + (0 if bid == "wall" or bid == "blast_door" else 1)
	structures.nav_changed.emit()
	structures._refresh_visuals()   # the sim is paused, so do it now
	hud.visible = false
	build.visible = false
	var view := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pair="):
			view = int(arg.split("=")[1])
	var dist := 12.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dist="):
			dist = float(arg.split("=")[1])
	cam.position = map.core_center + Vector3(-2.5 + view * 6.0, 0.0, 6.5)
	cam.pitch_deg = 30.0
	cam.photo_lock = true
	cam._target_distance = dist
	cam.distance = dist
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hide="):
			for nm in arg.split("=")[1].split(","):
				var nd := get_node_or_null(NodePath(nm))
				if nd is Node3D:
					(nd as Node3D).visible = false


## Dev helper: `-- --aliens=N --screenshot=path.png [--cam=x,z,dist]`.
func _screenshot_after(path: String) -> void:
	var warm := 1800
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--warm="):
			warm = int(arg.split("=")[1])
	for k in warm:
		_poll_fields()
		_step(1.0 / 60.0)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cam="):
			var v := arg.split("=")[1].split(",")
			cam.position = Vector3(float(v[0]), 0, float(v[1]))
			cam._target_distance = float(v[2])
			cam.distance = float(v[2])
	for arg in OS.get_cmdline_user_args():
		if arg == "--intel":
			build.toggle_intel()
		elif arg.begins_with("--tool="):
			build.select(arg.split("=")[1])
		elif arg == "--inspect":
			var best := -1
			for c: int in structures.turrets:
				if best < 0 or structures.tier_at(c) > structures.tier_at(best):
					best = c
			_select(best)
	await get_tree().create_timer(3.0).timeout
	if _heat_shot:
		_heat_on = true
		map.show_heatmap(field, true)
		await get_tree().create_timer(0.5).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[screenshot] saved ", path)
	get_tree().quit()
