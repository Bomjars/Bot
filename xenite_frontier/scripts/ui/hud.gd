class_name Hud
extends CanvasLayer
## Top-left perf/stat panel, top-centre core integrity, strain legend and
## banners. Readable at 1280x800.

var main: Node
var _stats: Label
var _legend: RichTextLabel
var _core_bar: ProgressBar
var _core_label: Label
var _bio_label: Label
var _col_label: RichTextLabel
var _log: RichTextLabel
var _log_lines: Array[String] = []
var _banner: Label
var _report: Label
var _help: Label
var _crosshair: Label
var _accum := 0.0
var detailed := true


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiStyle.theme()
	add_child(root)

	# left column: stats, controls help, benchmark report (stacked, never overlap)
	var col := VBoxContainer.new()
	col.position = Vector2(12, 12)
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(col)
	_stats = _panel_label(col, Vector2.ZERO)
	_help = _panel_label(col, Vector2.ZERO)
	_help.add_theme_font_size_override("font_size", 14)
	_help.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	_help.text = "1-9,0 / LB RB build tool    LMB (A) build / select    RMB (B) sell\nU (X) upgrade selected    R (Y) repair selected    I intel\n+/- (D-pad) swarm pressure    F5-F8 1k/5k/10k/20k\nB benchmark   Space (Start) pause   F10 reset   F11 free build\nPan WASD/stick/edge/MMB    Zoom wheel/Q,E/triggers\nF flow field   G gore   F1 (Back) toggle details + help"
	var lp2 := PanelContainer.new()
	lp2.add_theme_stylebox_override("panel", UiStyle.panel(0.7, Color(1.0, 0.55, 0.2, 0.6)))
	col.add_child(lp2)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.fit_content = true
	_log.custom_minimum_size = Vector2(430, 0)
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log.add_theme_font_size_override("normal_font_size", 15)
	lp2.add_child(_log)
	lp2.visible = false
	_report = _panel_label(col, Vector2.ZERO)
	_report.get_parent().visible = false

	var cp := PanelContainer.new()
	cp.add_theme_stylebox_override("panel", UiStyle.panel())
	cp.set_anchors_preset(Control.PRESET_CENTER_TOP)
	cp.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cp.position.y = 10
	root.add_child(cp)
	var cv := VBoxContainer.new()
	cp.add_child(cv)
	_core_label = Label.new()
	_core_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_core_label)
	_core_bar = ProgressBar.new()
	_core_bar.custom_minimum_size = Vector2(340, 14)
	_core_bar.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.2, 0.85, 1.0)
	_core_bar.add_theme_stylebox_override("fill", fill)
	cv.add_child(_core_bar)
	_bio_label = Label.new()
	_bio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bio_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.45))
	_bio_label.add_theme_font_size_override("font_size", 19)
	cv.add_child(_bio_label)
	_col_label = RichTextLabel.new()
	_col_label.bbcode_enabled = true
	_col_label.fit_content = true
	_col_label.custom_minimum_size = Vector2(520, 0)
	_col_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col_label.add_theme_font_size_override("normal_font_size", 16)
	cv.add_child(_col_label)

	var lp := PanelContainer.new()
	lp.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	lp.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	lp.position = Vector2(-12, 12)
	lp.add_theme_stylebox_override("panel", UiStyle.panel())
	root.add_child(lp)
	_legend = RichTextLabel.new()
	_legend.bbcode_enabled = true
	_legend.fit_content = true
	_legend.custom_minimum_size = Vector2(250, 0)
	_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lp.add_child(_legend)

	_banner = Label.new()
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 40)
	_banner.add_theme_color_override("font_color", Color(1.0, 0.35, 0.25))
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.add_theme_constant_override("outline_size", 8)
	_banner.visible = false
	root.add_child(_banner)

	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 34)
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.visible = false
	root.add_child(_crosshair)


func _panel_label(parent: Control, pos: Vector2) -> Label:
	var p := PanelContainer.new()
	p.position = pos
	p.add_theme_stylebox_override("panel", UiStyle.panel())
	parent.add_child(p)
	var l := Label.new()
	p.add_child(l)
	return l


func show_report(text: String) -> void:
	_report.text = text + "\n\n(press B to run again)"
	_report.get_parent().visible = true


## Colony event feed (abductions, rescues, losses).
func log_event(text: String, col: Color) -> void:
	_log_lines.append("[color=#%s]%s[/color]" % [col.to_html(false), text])
	while _log_lines.size() > 5:
		_log_lines.pop_front()
	_log.text = "\n".join(_log_lines)
	_log.get_parent().visible = true


func show_banner(text: String) -> void:
	_banner.text = text
	_banner.visible = text != ""


func set_crosshair(on: bool) -> void:
	_crosshair.visible = on


func _process(delta: float) -> void:
	var st: Structures = main.structures
	_core_bar.max_value = st.core_max
	_core_bar.value = st.core_hp
	_core_label.text = "OUTPOST CORE  %d / %d%s" % [int(st.core_hp), int(st.core_max), "   (benchmark: invulnerable)" if st.core_invulnerable else ""]
	var cs: ColonistSystem = main.colonists
	var crewed := 0
	for t: Turret in st.turrets.values():
		if t.crewed:
			crewed += 1
	_col_label.text = "[center]COLONISTS [b]%d[/b]   crewing %d/%d turrets   reserve %d   [color=#ffa060]carried %d[/color]   recovering %d   [color=#ff6a5a]lost %d[/color][/center]" % [
		cs.alive(), crewed, st.turrets.size(), cs.count_state(ColonistSystem.S.RESERVE), cs.count_state(ColonistSystem.S.CARRIED),
		cs.count_state(ColonistSystem.S.RECOVERING), cs.taken + cs.killed]
	var eco: Economy = main.economy
	_bio_label.text = ("BIOMASS  %d" % int(eco.biomass)) + ("   [FREE BUILD]" if eco.free_build else "") + ("   +%d/min   drones %d" % [int(eco.income_per_min()), main.harvester.drone_count()])
	_accum += delta
	if _accum < 0.25:
		return
	_accum = 0.0
	var swarm: Swarm = main.swarm
	var combat: Combat = main.combat
	var rid := get_viewport().get_viewport_rid()
	var fps := Engine.get_frames_per_second()
	var txt := "XENITE FRONTIER  -  M4 colony sandbox\n"
	txt += "FPS %d   (%.1f ms)\n" % [fps, 1000.0 / maxf(fps, 1)]
	txt += "Aliens: %d   swarm pressure %d\n" % [swarm.total(), main.target_count]
	txt += "Kills: %d   dodged shots: %d\n" % [combat.kills, combat.dodges]
	txt += "Corpses: %d (%d charred)   climbable walls: %d\n" % [main.corpses.count, main.corpses.charred_count, main.map.climbable_count()]
	txt += "Structures lost: %d   turrets: %d\n" % [st.destroyed_count, st.turrets.size()]
	txt += "Biomass collected %d   spent %d   lost to decay %d\n" % [int(main.economy.collected), int(main.economy.spent), int(main.corpses.biomass_lost)]
	txt += "Corpses eaten %d (human %d)   biggest alien x%.2f\n" % [main.corpses.eaten + main.corpses.humans_eaten, main.corpses.humans_eaten, main.combat.biggest]
	if detailed:
		txt += "Swarm sim %.2f ms   combat %.2f ms   fx %.2f ms\n" % [swarm.sim_usec / 1000.0, combat.combat_usec / 1000.0, main.fx.update_usec / 1000.0]
		txt += "Render CPU %.2f ms   GPU %.2f ms   draws %d\n" % [
			RenderingServer.viewport_get_measured_render_time_cpu(rid),
			RenderingServer.viewport_get_measured_render_time_gpu(rid),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)]
		txt += "Flow fields %.1f / %.1f ms (surface/burrow)" % [swarm.field.build_usec / 1000.0, swarm.bfield.build_usec / 1000.0]
	if swarm.paused:
		txt += "\n[SIM PAUSED]"
	var b: BenchmarkRunner = main.bench
	if b.running():
		txt += "\n" + b.status_text()
	_stats.text = txt
	_help.get_parent().visible = detailed

	var lg := "[b]SWARM[/b]  alive / killed\n"
	for p in swarm.pools:
		lg += "[color=%s]■[/color] %s  [color=#cdd]%d[/color] / [color=#9aa]%d[/color]\n" % [UiStyle.alien_color(p.def.id), p.def.name, p.count, combat.kills_by_alien[p.type_id]]
	var tot := 0.0
	for v in combat.damage_by_type:
		tot += v
	if tot > 0.0:
		lg += "[b]DAMAGE DEALT[/b]\n"
		for d in GameConfig.DMG_COUNT:
			lg += "[color=#%s]%s[/color] %d%%\n" % [GameConfig.damage_color(d).to_html(false), GameConfig.damage_name(d), int(100.0 * combat.damage_by_type[d] / tot)]
	_legend.text = lg
