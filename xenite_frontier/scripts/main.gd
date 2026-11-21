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
	structures.built.connect(func(c, id): if id == "harvester_bay": harvester.add_bay(c, structures.tier_at(c)))
	structures.removed.connect(func(c, id):
		if id == "harvester_bay": harvester.remove_bay(c)
		if c == _selected: _select(-1))
	structures.upgraded.connect(func(c, id, t): if id == "harvester_bay": harvester.set_tier(c, t))
	economy.deposited.connect(func(amount, pos): fx.float_text(pos, "+%d" % int(round(amount)), Color(0.5, 1.0, 0.4)))

	colonists = ColonistSystem.new()
	colonists.name = "Colonists"
	add_child(colonists)
	colonists.setup(map, structures, corpses, fx, hfield)
	structures.built.connect(colonists.on_structure_built)
	structures.removed.connect(colonists.on_structure_removed)
	colonists.event.connect(_on_colonist_event)

	structures.reset()
	colonists.reset()
	field.build()
	bfield.build()
	rfield.build()
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
	build.economy = economy
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
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--benchmark"):
			bench.quit_when_done = true
			var parts := arg.split("=")
			_start_benchmark(int(parts[1]) if parts.size() > 1 else -1)
		elif arg.begins_with("--aliens="):
			target_count = int(arg.split("=")[1])
		elif arg == "--bot":
			_bot = true
		elif arg == "--free-build":
			economy.free_build = true
		elif arg == "--stuck-report":
			_stuck_report = true
		elif arg.begins_with("--combat-test"):
			var parts := arg.split("=")
			_test_seconds = float(parts[1]) if parts.size() > 1 else 40.0
		elif arg == "--showcase":
			_showcase.call_deferred()
		elif arg.begins_with("--screenshot="):
			_screenshot_after(arg.split("=")[1])


func _build_environment() -> void:
	# alien sky: violet zenith, dusty salmon horizon, a small hot white sun
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.10, 0.06, 0.16)
	sky_mat.sky_horizon_color = Color(0.62, 0.36, 0.30)
	sky_mat.ground_bottom_color = Color(0.12, 0.07, 0.06)
	sky_mat.ground_horizon_color = Color(0.5, 0.3, 0.24)
	sky_mat.sun_angle_max = 8.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.65
	env.ambient_light_color = Color(0.55, 0.42, 0.5)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_hdr_threshold = 1.1
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.55, 0.32, 0.25)
	env.fog_density = 0.0035
	env.fog_sky_affect = 0.4
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.05
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.82, 0.68)
	sun.light_energy = 1.25
	sun.rotation_degrees = Vector3(-33, -40, 0)   # low sun: relief casts shadows
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 140.0
	add_child(sun)
	# cool bounce from the opposite side so shadowed cliffs read
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.45, 0.5, 0.8)
	fill.light_energy = 0.25
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
	swarm.set_far_lod(cam.distance > 70.0)
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
	swarm.simulate(dt)
	combat.process_swarm_events()
	colonists.process_swarm(swarm, combat)
	combat.build_grid()
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
		else:
			var c := _hover_cell()
			_select(c if structures.ids.has(c) else -1)
	elif event.is_action_pressed("demolish"):
		if build.selected == "" and _selected >= 0 and not _pad_mode and _hover_cell() != _selected:
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
	if _selected < 0:
		return
	var err := ""
	match action:
		"upgrade": err = structures.upgrade(_selected)
		"repair": err = structures.repair(_selected)
		"sell":
			structures.sell(_selected)
			_select(-1)
			return
	if err != "":
		build.toast(err)
	_select(_selected)


## Text + button state for the Inspector panel.
func _inspector_info(c: int) -> Dictionary:
	if not structures.ids.has(c):
		return {}
	var id: String = structures.ids[c]
	var d: Dictionary = structures.defs[id]
	var tier := structures.tier_at(c)
	var tname: String = GameConfig.tiers[clampi(tier - 1, 0, GameConfig.tiers.size() - 1)].get("name", str(tier))
	var lines: PackedStringArray = []
	var maxt := GameConfig.max_tier(id)
	var head := "[b]%s[/b]" % d.name
	if maxt > 1:
		head += "   Tier %s" % tname
	if d.has("damage_type"):
		var di := GameConfig.damage_index(d.damage_type)
		head += "   [color=#%s]%s[/color]" % [GameConfig.damage_color(di).to_html(false), GameConfig.damage_name(di)]
	lines.append(head)
	lines.append("HP %d / %d" % [int(map.shp[c]), int(map.smax[c])])
	var up := structures.upgrade_cost(c)
	if structures.turrets.has(c):
		var t: Turret = structures.turrets[c]
		var line := "Damage %.0f   Range %.1fm   Fire %.2f/s   Crew eff. %d%%" % [t.dmg, t.rng, t.fire_rate(), roundi(t.crew_efficiency * 100)]
		lines.append(line)
		if up >= 0:
			var nt: Dictionary = GameConfig.tiers[tier]
			lines.append("[color=#9fd]Next: damage %.0f, range %.1fm, crew eff. %d%%[/color]" % [float(d.damage) * float(nt.damage), float(d.range) * float(nt.range), roundi(float(nt.crew_efficiency) * 100)])
		else:
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
		lines.append("Light radius %.0fm   (turrets need light at night - M5)" % structures.light_radius())
	elif map.climb[c]:
		lines.append("[color=#bf8]Corpse pile alongside: the swarm can climb this![/color]")
	var rc := structures.repair_cost(c)
	return {
		"text": "\n".join(lines),
		"upgrade_label": ("Upgrade [U/X]  %d" % up) if up >= 0 else ("Max tier" if maxt > 1 else ""),
		"can_upgrade": up >= 0 and economy.can_afford(up),
		"repair_label": ("Repair [R/Y]  %d" % rc) if rc > 0 else "Repair",
		"can_repair": rc > 0 and economy.can_afford(rc),
		"sell_label": "Sell [RMB/B]  +%d" % structures.sell_value(c),
	}


func _update_ghost() -> void:
	# drag-painting walls/doors, drag-demolish
	if not bench.running():
		if Input.is_action_pressed("primary") and build.selected in ["wall", "blast_door"]:
			_try_build()
		elif Input.is_action_pressed("demolish") and build.selected != "":
			structures.sell(_hover_cell())
	var c := _hover_cell()
	var show_range := 0.0
	if build.selected != "" and c >= 0:
		var ok := map.can_build(c) and economy.can_afford(GameConfig.build_cost(build.selected))
		var d: Dictionary = structures.defs[build.selected]
		var hgt := float(d.get("height", 1.4))
		_ghost.visible = true
		_ghost.scale = Vector3(0.98, hgt, 0.98)
		_ghost.position = map.cell_ground(c) + Vector3(0, hgt * 0.5, 0)
		_ghost_mat.albedo_color = Color(0.3, 1.0, 0.5, 0.35) if ok else Color(1.0, 0.25, 0.2, 0.35)
		show_range = _range_of(build.selected, 1, -1)
	else:
		_ghost.visible = false
		if _selected >= 0:
			c = _selected
			show_range = _range_of(structures.id_at(c), structures.tier_at(c), c)
		elif c >= 0 and structures.ids.has(c):
			show_range = _range_of(structures.id_at(c), structures.tier_at(c), c)
	_ring.visible = show_range > 0.0
	if _ring.visible:
		_ring.position = map.cell_ground(c) + Vector3(0, 0.08, 0)
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
	hud.show_banner("OUTPOST OVERRUN\nThe swarm has gutted the core.\nPress F10 to rebuild")


func reset_outpost() -> void:
	_select(-1)
	swarm.clear()
	harvester.clear()
	corpses.clear()
	fx.clear()
	combat.reset_stats()
	economy.reset()
	structures.reset()
	colonists.reset()
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
			[-3, -2, "harvester_bay"], [3, -8, "shock_grid"], [-10, 0, "mortar"],
			[8, -2, "autocannon"], [-2, -3, "flamethrower"], [10, 0, "railgun"],
		])
	# build next planned item if affordable
	if not _bot_plan.is_empty():
		var e: Array = _bot_plan[0]
		var c := map.idx(core.x + e[0], core.y + e[1])
		if not map.can_build(c):
			_bot_plan.pop_front()
		elif economy.can_afford(GameConfig.build_cost(e[2])):
			structures.try_build(c, e[2])
			_bot_plan.pop_front()
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
	lines.append("colonists alive %d/%d  crewing %d  reserve %d  recovering %d  abductions %d  rescued %d  taken %d  mauled %d" % [
		colonists.alive(), colonists.colonists.size(), colonists.count_state(ColonistSystem.S.CREWING), colonists.count_state(ColonistSystem.S.RESERVE),
		colonists.count_state(ColonistSystem.S.RECOVERING), colonists.abductions, colonists.rescued, colonists.taken, colonists.killed])
	var crewed := 0
	for t: Turret in structures.turrets.values():
		if t.crewed:
			crewed += 1
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
	var row := map.core_center + Vector3(-8.0, 0, -26.0)
	var poses := [0.0, 0.5, 1.0, -2.0, -1.0]
	for t in swarm.pools.size():
		var p := swarm.pools[t]
		for k in poses.size():
			var x := row.x + t * 3.2
			var z := row.z + k * 2.6 - (1.5 if t == 5 else 0.0)
			var i := p.spawn(x, z, swarm.rng)
			var o := i * AlienPool.STRIDE
			p.buf[o] = 1.0; p.buf[o + 2] = 0.0; p.buf[o + 8] = 0.0; p.buf[o + 10] = 1.0
			p.buf[o + 5] = 1.0
			p.buf[o + 7] = map.height_at(x, z)
			p.buf[o + 15] = poses[k]
	# photo mode: no UI, close low camera (pick the strain pair with --pair=N)
	hud.visible = false
	build.visible = false
	var pair := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pair="):
			pair = int(arg.split("=")[1])
	cam.position = row + Vector3(1.6 + pair * 6.4, 1.0, 6.0)
	cam.pitch_deg = 24.0
	cam.photo_lock = true
	cam._target_distance = 9.0
	cam.distance = 9.0


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
