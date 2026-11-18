class_name BenchmarkHUD
extends CanvasLayer
## M1 debug HUD: perf counters, strain legend and controls. Font sizes are
## chosen to stay readable at 1280x800 (Steam Deck).

var main: Node
var _stats: Label
var _legend: RichTextLabel
var _help: Label
var _report: Label
var _accum := 0.0


func _ready() -> void:
	var theme := Theme.new()
	theme.default_font_size = 17
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme
	add_child(root)

	_stats = _panel_label(root, Vector2(12, 12))
	_report = _panel_label(root, Vector2(12, 300))
	_report.get_parent().visible = false

	var lp := PanelContainer.new()
	lp.position = Vector2(-250, 12)
	lp.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	lp.add_theme_stylebox_override("panel", _style())
	root.add_child(lp)
	_legend = RichTextLabel.new()
	_legend.bbcode_enabled = true
	_legend.fit_content = true
	_legend.custom_minimum_size = Vector2(230, 0)
	_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lp.add_child(_legend)

	_help = Label.new()
	_help.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_help.position = Vector2(12, -64)
	_help.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	_help.text = "Pan WASD/arrows/edge/MMB drag/left stick   Zoom wheel/Q,E/triggers   LMB/(A) toggle wall   F/(X) flow-field   B/(Y) benchmark\n1-4 presets 1k/5k/10k/20k   +/- (LB/RB) +-1000   Space/(Start) pause sim   R reset walls   F1/(Back) hide HUD"
	root.add_child(_help)


func _style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.05, 0.78)
	sb.border_color = Color(0.2, 0.75, 0.9, 0.6)
	sb.border_width_left = 2
	sb.content_margin_left = 10; sb.content_margin_right = 10
	sb.content_margin_top = 6; sb.content_margin_bottom = 6
	return sb


func _panel_label(parent: Control, pos: Vector2) -> Label:
	var p := PanelContainer.new()
	p.position = pos
	p.add_theme_stylebox_override("panel", _style())
	parent.add_child(p)
	var l := Label.new()
	p.add_child(l)
	return l


func show_report(text: String) -> void:
	_report.text = text + "\n\n(press B to run again)"
	_report.get_parent().visible = true


func _process(delta: float) -> void:
	_accum += delta
	if _accum < 0.25:
		return
	_accum = 0.0
	var swarm: Swarm = main.swarm
	var rid := get_viewport().get_viewport_rid()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var fps := Engine.get_frames_per_second()
	var txt := "XENITE FRONTIER  -  M1 swarm test range\n"
	txt += "FPS %d   (%.1f ms)\n" % [fps, 1000.0 / maxf(fps, 1)]
	txt += "Aliens on field: %d / target %d\n" % [swarm.total(), main.target_count]
	txt += "Swarm sim  %.2f ms\n" % (swarm.sim_usec / 1000.0)
	txt += "MultiMesh upload %.2f ms\n" % (swarm.upload_usec / 1000.0)
	txt += "Render CPU %.2f ms   GPU %.2f ms\n" % [cpu, gpu]
	txt += "Draw calls %d   Objects %d\n" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)]
	txt += "Flow field rebuild %.2f ms (%dx%d)\n" % [swarm.field.build_usec / 1000.0, swarm.map.w, swarm.map.h]
	txt += "Reached core: %d%s" % [swarm.reached_core, "   [SIM PAUSED]" if swarm.paused else ""]
	var b: BenchmarkRunner = main.bench
	if b.running():
		txt += "\n" + b.status_text()
	_stats.text = txt

	var cols := ["#dcc775", "#a8331a", "#73ff33", "#8038d1", "#eb8c24", "#d11a6b"]
	var lg := "[b]SWARM STRAINS[/b]\n"
	for p in swarm.pools:
		lg += "[color=%s]■[/color] %s  [color=#9aa]%d[/color]\n" % [cols[p.type_id % cols.size()], p.def.name, p.count]
	_legend.text = lg
