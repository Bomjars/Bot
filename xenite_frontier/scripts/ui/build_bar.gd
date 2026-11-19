class_name BuildBar
extends CanvasLayer
## Bottom build bar (keys 1-8 / LB-RB), an info card for the selected tool
## that shows its counters (readable with a controller - no hover needed),
## and the Intel panel: the full damage-type vs strain counter table.

signal tool_changed(id: String)

const TOOLS := ["wall", "blast_door", "autocannon", "flamethrower", "railgun", "shock_grid", "mortar", "seismic_spike"]

var selected := ""
var _buttons: Array[Button] = []
var _info: RichTextLabel
var _info_panel: PanelContainer
var _intel: PanelContainer


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiStyle.theme()
	add_child(root)

	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.position.y = -12
	bar.add_theme_constant_override("separation", 6)
	root.add_child(bar)
	for k in TOOLS.size():
		var id: String = TOOLS[k]
		var d := _def(id)
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(112, 58)
		b.text = "%d  %s" % [k + 1, d.get("name", id)]
		b.autowrap_mode = TextServer.AUTOWRAP_WORD
		b.add_theme_font_size_override("font_size", 15)
		b.tooltip_text = tool_text(id, false)
		var col := Color(0.5, 0.56, 0.62)
		if d.has("damage_type"):
			col = GameConfig.damage_color(GameConfig.damage_index(d.damage_type))
		elif id == "blast_door":
			col = Color(0.85, 0.7, 0.2)
		var sb := UiStyle.panel(0.85, col)
		sb.border_width_bottom = 4
		sb.border_width_left = 0
		b.add_theme_stylebox_override("normal", sb)
		var sbh := sb.duplicate()
		sbh.bg_color = Color(0.1, 0.13, 0.16, 0.95)
		b.add_theme_stylebox_override("hover", sbh)
		var sbp := sb.duplicate()
		sbp.bg_color = col.darkened(0.55)
		sbp.border_width_top = 2
		b.add_theme_stylebox_override("pressed", sbp)
		b.add_theme_stylebox_override("hover_pressed", sbp)
		b.pressed.connect(select.bind(id))
		bar.add_child(b)
		_buttons.append(b)

	_info_panel = PanelContainer.new()
	_info_panel.add_theme_stylebox_override("panel", UiStyle.panel())
	_info_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_info_panel.position = Vector2(12, -90)
	root.add_child(_info_panel)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.custom_minimum_size = Vector2(330, 0)
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_panel.add_child(_info)
	_info_panel.visible = false

	_intel = _build_intel()
	root.add_child(_intel)
	_intel.visible = false


func _def(id: String) -> Dictionary:
	for d in GameConfig.structure_defs:
		if d.id == id:
			return d
	for d in GameConfig.turret_defs:
		if d.id == id:
			return d
	return {}


## Text card for a tool. bbcode=true for the info panel, plain for tooltips.
func tool_text(id: String, bbcode := true) -> String:
	var d := _def(id)
	var lines: PackedStringArray = []
	if d.has("damage_type"):
		var di := GameConfig.damage_index(d.damage_type)
		var dname := GameConfig.damage_name(di)
		if bbcode:
			lines.append("[b]%s[/b]  [color=#%s]%s[/color]" % [d.name, GameConfig.damage_color(di).to_html(false), dname])
		else:
			lines.append("%s  (%s)" % [d.name, dname])
		lines.append(d.get("role", ""))
		var stats := "Range %.0fm   %.1f shots/s   %.0f dmg" % [d.range, d.fire_rate, d.damage]
		if d.has("min_range"):
			stats += "   min %.0fm" % d.min_range
		lines.append(stats)
		var cs := GameConfig.counter_summary(di)
		if bbcode:
			cs = cs.replace("Strong vs:", "[color=#7dff7a]Strong vs:[/color]").replace("Poor vs:", "[color=#ff7a6a]Poor vs:[/color]")
		lines.append(cs)
	else:
		lines.append(("[b]%s[/b]" % d.name) if bbcode else d.name)
		lines.append(d.get("role", ""))
		lines.append("HP %d   height %.1fm" % [d.hp, d.height])
	lines.append("LMB / (A) build    RMB / (B) demolish    Esc deselect")
	return "\n".join(lines)


func select(id: String) -> void:
	selected = "" if id == selected else id
	for k in TOOLS.size():
		_buttons[k].set_pressed_no_signal(TOOLS[k] == selected)
	_info_panel.visible = selected != ""
	if selected != "":
		_info.text = tool_text(selected)
	tool_changed.emit(selected)


func select_index(k: int) -> void:
	if k >= 0 and k < TOOLS.size():
		select(TOOLS[k])


func cycle(dir: int) -> void:
	var k := TOOLS.find(selected)
	k = wrapi(k + dir, 0, TOOLS.size()) if k >= 0 else (0 if dir > 0 else TOOLS.size() - 1)
	select(TOOLS[k])


func toggle_intel() -> void:
	_intel.visible = not _intel.visible


func _build_intel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UiStyle.panel(0.92))
	p.set_anchors_preset(Control.PRESET_CENTER)
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	var v := VBoxContainer.new()
	p.add_child(v)
	var title := Label.new()
	title.text = "XENOBIOLOGY INTEL - damage vs strain   (I / D-pad right to close)"
	v.add_child(title)
	var g := GridContainer.new()
	g.columns = GameConfig.DMG_COUNT + 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 4)
	v.add_child(g)
	var hdr := ["Strain", "Trait"]
	for d in GameConfig.DMG_COUNT:
		hdr.append(GameConfig.damage_name(d))
	for k in hdr.size():
		var l := Label.new()
		l.text = hdr[k]
		if k >= 2:
			l.add_theme_color_override("font_color", GameConfig.damage_color(k - 2))
		g.add_child(l)
	for a in GameConfig.alien_defs.size():
		var ad: Dictionary = GameConfig.alien_defs[a]
		var nl := Label.new()
		nl.text = ad.name
		nl.add_theme_color_override("font_color", Color(UiStyle.alien_color(ad.id)))
		g.add_child(nl)
		var tl := Label.new()
		tl.text = ad.trait
		tl.custom_minimum_size = Vector2(300, 0)
		tl.autowrap_mode = TextServer.AUTOWRAP_WORD
		tl.add_theme_font_size_override("font_size", 14)
		g.add_child(tl)
		for d in GameConfig.DMG_COUNT:
			var m := GameConfig.multiplier(a, d)
			var cl := Label.new()
			cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			if m > 1.0:
				cl.text = "WEAK %d%%" % int(m * 100)
				cl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.45))
			elif m < 1.0:
				cl.text = "resists %d%%" % int(m * 100)
				cl.add_theme_color_override("font_color", Color(1.0, 0.45, 0.35))
			else:
				cl.text = "-"
				cl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			g.add_child(cl)
	var note := Label.new()
	note.text = "Burrowers underground can only be hit by Seismic. Snatchers dodge 35% of aimed shots (Autocannon, Railgun)."
	note.add_theme_font_size_override("font_size", 14)
	v.add_child(note)
	return p
