class_name BuildBar
extends CanvasLayer
## Bottom build bar (keys 1-9, 0 / LB-RB) with Biomass costs, an info card
## for the selected tool that shows its counters (readable with a controller -
## no hover needed), the structure Inspector (upgrade / repair / sell) and the
## Intel panel: the full damage-type vs strain counter table.

signal tool_changed(id: String)
signal inspector_action(action: String)

const TOOLS := ["wall", "blast_door", "floodlight", "harvester_bay", "autocannon", "flamethrower", "railgun", "shock_grid", "mortar", "seismic_spike"]

var selected := ""
var economy: Economy
var _buttons: Array[Button] = []
var _info: RichTextLabel
var _info_panel: PanelContainer
var _intel: PanelContainer
var _insp_panel: PanelContainer
var _insp_text: RichTextLabel
var _btn_upgrade: Button
var _btn_repair: Button
var _btn_sell: Button
var _toast: Label
var _toast_t := 0.0


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
	bar.position.y = -10
	bar.add_theme_constant_override("separation", 4)
	root.add_child(bar)
	for k in TOOLS.size():
		var id: String = TOOLS[k]
		var d := _def(id)
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(110, 62)
		b.text = "%d %s\n%d" % [(k + 1) % 10, d.get("name", id), GameConfig.build_cost(id)]
		b.autowrap_mode = TextServer.AUTOWRAP_WORD
		b.add_theme_font_size_override("font_size", 14)
		b.tooltip_text = tool_text(id, false)
		var col := Color(0.5, 0.56, 0.62)
		if d.has("damage_type"):
			col = GameConfig.damage_color(GameConfig.damage_index(d.damage_type))
		elif id == "blast_door":
			col = Color(0.85, 0.7, 0.2)
		elif id == "floodlight":
			col = Color(1.0, 0.95, 0.75)
		elif id == "harvester_bay":
			col = Color(0.4, 1.0, 0.35)
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
	_info_panel.position = Vector2(12, -86)
	root.add_child(_info_panel)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.custom_minimum_size = Vector2(340, 0)
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_panel.add_child(_info)
	_info_panel.visible = false

	_build_inspector(root)

	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.position.y = -110
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_color_override("font_color", Color(1.0, 0.55, 0.4))
	_toast.add_theme_color_override("font_outline_color", Color.BLACK)
	_toast.add_theme_constant_override("outline_size", 6)
	root.add_child(_toast)

	_intel = _build_intel()
	root.add_child(_intel)
	_intel.visible = false


func _build_inspector(root: Control) -> void:
	_insp_panel = PanelContainer.new()
	_insp_panel.add_theme_stylebox_override("panel", UiStyle.panel(0.88, Color(0.4, 1.0, 0.35, 0.7)))
	_insp_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_insp_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_insp_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_insp_panel.position = Vector2(-12, -86)
	root.add_child(_insp_panel)
	var v := VBoxContainer.new()
	_insp_panel.add_child(v)
	_insp_text = RichTextLabel.new()
	_insp_text.bbcode_enabled = true
	_insp_text.fit_content = true
	_insp_text.custom_minimum_size = Vector2(360, 0)
	_insp_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_insp_text)
	var h := HBoxContainer.new()
	v.add_child(h)
	_btn_upgrade = _insp_button(h, "upgrade")
	_btn_repair = _insp_button(h, "repair")
	_btn_sell = _insp_button(h, "sell")
	_insp_panel.visible = false


func _insp_button(parent: Control, action: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 15)
	b.pressed.connect(func(): inspector_action.emit(action))
	parent.add_child(b)
	return b


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
	var cost := GameConfig.build_cost(id)
	if d.has("damage_type"):
		var di := GameConfig.damage_index(d.damage_type)
		var dname := GameConfig.damage_name(di)
		if bbcode:
			lines.append("[b]%s[/b]  [color=#%s]%s[/color]   [color=#8f8]%d Biomass[/color]" % [d.name, GameConfig.damage_color(di).to_html(false), dname, cost])
		else:
			lines.append("%s  (%s)  %d Biomass" % [d.name, dname, cost])
		lines.append(d.get("role", ""))
		var stats := "Range %.0fm   %.1f shots/s   %.0f dmg" % [d.range, d.fire_rate, d.damage]
		if d.has("min_range"):
			stats += "   min %.0fm" % d.min_range
		lines.append(stats)
		var cs := GameConfig.counter_summary(di)
		if bbcode:
			cs = cs.replace("Strong vs:", "[color=#7dff7a]Strong vs:[/color]").replace("Poor vs:", "[color=#ff7a6a]Poor vs:[/color]")
		lines.append(cs)
		var up: Array = GameConfig.econ("upgrade_costs").get(id, [])
		if not up.is_empty():
			lines.append("Upgrades: tier II %d, tier III %d Biomass" % [up[0], up[1]])
	else:
		lines.append(("[b]%s[/b]   [color=#8f8]%d Biomass[/color]" % [d.name, cost]) if bbcode else "%s  %d Biomass" % [d.name, cost])
		lines.append(d.get("role", ""))
		lines.append("HP %d   height %.1fm" % [d.hp, d.height])
		if id == "harvester_bay":
			var hv := GameConfig.econ("harvester")
			lines.append("Drones %s   range %s m by tier" % ["/".join(PackedStringArray(hv.get("drones_per_tier", []).map(func(x): return str(int(x))))), "/".join(PackedStringArray(hv.get("range_per_tier", []).map(func(x): return str(int(x)))))])
	lines.append("LMB / (A) build    RMB / (B) sell    Esc deselect")
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


## Greys out tools you cannot afford.
func refresh_affordability() -> void:
	if economy == null:
		return
	for k in TOOLS.size():
		var ok := economy.can_afford(GameConfig.build_cost(TOOLS[k]))
		_buttons[k].modulate = Color.WHITE if ok else Color(1, 1, 1, 0.45)


func toast(text: String) -> void:
	_toast.text = text
	_toast_t = 1.8


func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t, 0.0, 1.0)


## Inspector for a selected structure. info = {} hides it.
func show_inspector(info: Dictionary) -> void:
	_insp_panel.visible = not info.is_empty()
	if info.is_empty():
		return
	_insp_text.text = info.text
	_btn_upgrade.text = info.upgrade_label
	_btn_upgrade.disabled = not info.can_upgrade
	_btn_upgrade.visible = info.upgrade_label != ""
	_btn_repair.text = info.repair_label
	_btn_repair.disabled = not info.can_repair
	_btn_sell.text = info.sell_label


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
		nl.text = "%s\n%d Biomass" % [ad.name, int(GameConfig.corpse_biomass(ad.id))]
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
	note.text = "Burrowers underground can only be hit by Seismic. Snatchers dodge 35% of aimed shots.\nIncendiary kills char the corpse: charred corpses hold no Biomass."
	note.add_theme_font_size_override("font_size", 14)
	v.add_child(note)
	return p
