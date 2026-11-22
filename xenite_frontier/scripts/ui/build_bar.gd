class_name BuildBar
extends CanvasLayer
## Bottom build bar (keys 1-9, 0 / LB-RB): a picture of each building /
## turret (ItemIcons renders the real models), its name and Biomass cost, an info card
## for the selected tool that shows its counters (readable with a controller -
## no hover needed), the structure Inspector (upgrade / repair / sell) and the
## Intel panel: the full damage-type vs strain counter table.

signal tool_changed(id: String)
signal inspector_action(action: String)

const CATEGORIES := {
	"DEFENCE": ["wall", "blast_door", "floodlight", "guard_post"],
	"TURRETS": ["autocannon", "flamethrower", "railgun", "shock_grid", "mortar", "seismic_spike"],
	"COLONY": ["harvester_bay", "mining_rig", "hab_module", "barracks", "bio_refinery", "fabricator", "armory", "medbay"],
}
const TOOLS := ["wall", "blast_door", "floodlight", "guard_post", "autocannon", "flamethrower", "railgun", "shock_grid", "mortar", "seismic_spike",
	"harvester_bay", "mining_rig", "hab_module", "barracks", "bio_refinery", "fabricator", "armory", "medbay"]

var selected := ""
var category := "DEFENCE"
var economy: Economy
var structures: Structures
var _cat_buttons := {}
var _buttons: Array[Button] = []
var _btn_icon: Array[TextureRect] = []
var _btn_name: Array[Label] = []
var _btn_cost: Array[Label] = []
var icons: ItemIcons
var _info_icon: TextureRect
var _insp_icon: TextureRect
var _info: RichTextLabel
var _info_panel: PanelContainer
var _intel: PanelContainer
var _insp_panel: PanelContainer
var _insp_text: RichTextLabel
var _insp_row: HBoxContainer
var _insp_sig := ""
var _toast: Label
var _toast_t := 0.0


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiStyle.theme()
	add_child(root)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	col.grow_horizontal = Control.GROW_DIRECTION_BOTH
	col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	col.position.y = -8
	col.add_theme_constant_override("separation", 2)
	root.add_child(col)
	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 4)
	col.add_child(tabs)
	for cat: String in CATEGORIES:
		var tb := Button.new()
		tb.focus_mode = Control.FOCUS_NONE
		tb.toggle_mode = true
		tb.text = cat
		tb.custom_minimum_size = Vector2(120, 28)
		tb.add_theme_font_size_override("font_size", 14)
		tb.pressed.connect(set_category.bind(cat))
		tabs.add_child(tb)
		_cat_buttons[cat] = tb
	var hint := Label.new()
	hint.text = "  Tab: next category"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	tabs.add_child(hint)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 4)
	col.add_child(bar)
	for k in TOOLS.size():
		var id: String = TOOLS[k]
		var d := _def(id)
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(112, 118)
		b.tooltip_text = tool_text(id, false)
		# picture on top, then "key  name", then the cost
		var v := VBoxContainer.new()
		v.set_anchors_preset(Control.PRESET_FULL_RECT)
		v.offset_left = 4
		v.offset_right = -4
		v.offset_top = 3
		v.offset_bottom = -6
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_theme_constant_override("separation", 0)
		b.add_child(v)
		var tr := TextureRect.new()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_EXPAND_FILL
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(tr)
		var nl := Label.new()
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nl.add_theme_font_size_override("font_size", 13)
		nl.clip_text = true
		v.add_child(nl)
		var cl := Label.new()
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cl.add_theme_font_size_override("font_size", 13)
		v.add_child(cl)
		_btn_icon.append(tr)
		_btn_name.append(nl)
		_btn_cost.append(cl)
		var accent := Color(0.6, 0.62, 0.66)
		if d.has("damage_type"):
			accent = GameConfig.damage_color(GameConfig.damage_index(d.damage_type))
		elif id in ["blast_door", "guard_post"]:
			accent = Color(0.95, 0.78, 0.1)
		elif id == "floodlight":
			accent = Color(1.0, 0.95, 0.75)
		elif id in ["harvester_bay", "bio_refinery"]:
			accent = Color(0.4, 1.0, 0.35)
		elif id == "mining_rig":
			accent = Color(0.2, 0.95, 0.85)
		var sb := UiStyle.panel(0.85, accent)
		sb.border_width_bottom = 4
		sb.border_width_left = 0
		b.add_theme_stylebox_override("normal", sb)
		var sbh := sb.duplicate()
		sbh.bg_color = Color(0.1, 0.13, 0.16, 0.95)
		b.add_theme_stylebox_override("hover", sbh)
		var sbp := sb.duplicate()
		sbp.bg_color = accent.darkened(0.55)
		sbp.border_width_top = 2
		b.add_theme_stylebox_override("pressed", sbp)
		b.add_theme_stylebox_override("hover_pressed", sbp)
		b.pressed.connect(select.bind(id))
		bar.add_child(b)
		_buttons.append(b)
	set_category("DEFENCE")

	_info_panel = PanelContainer.new()
	_info_panel.add_theme_stylebox_override("panel", UiStyle.panel())
	# bottom-right, where the Inspector goes (never open at the same time),
	# clear of the help text and event log on the left
	_info_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_info_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_info_panel.position = Vector2(-12, -170)
	root.add_child(_info_panel)
	var ih := HBoxContainer.new()
	ih.add_theme_constant_override("separation", 8)
	_info_panel.add_child(ih)
	_info_icon = _picture(112)
	ih.add_child(_info_icon)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.custom_minimum_size = Vector2(340, 0)
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ih.add_child(_info)
	_info_panel.visible = false

	_build_inspector(root)

	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.position.y = -140
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
	_insp_panel.position = Vector2(-12, -170)
	root.add_child(_insp_panel)
	var hh := HBoxContainer.new()
	hh.add_theme_constant_override("separation", 8)
	_insp_panel.add_child(hh)
	_insp_icon = _picture(96)
	hh.add_child(_insp_icon)
	var v := VBoxContainer.new()
	hh.add_child(v)
	_insp_text = RichTextLabel.new()
	_insp_text.bbcode_enabled = true
	_insp_text.fit_content = true
	_insp_text.custom_minimum_size = Vector2(360, 0)
	_insp_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_insp_text)
	_insp_row = HBoxContainer.new()
	v.add_child(_insp_row)
	_insp_panel.visible = false


func _picture(px: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.custom_minimum_size = Vector2(px, px)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.visible = false
	return tr


## Called when ItemIcons has rendered the pictures.
func apply_icons() -> void:
	if icons == null:
		return
	for k in TOOLS.size():
		_btn_icon[k].texture = icons.get_icon(TOOLS[k])
	if selected != "":
		_set_picture(_info_icon, selected)


func _set_picture(tr: TextureRect, id: String) -> void:
	var tex: Texture2D = icons.get_icon(id) if icons and id != "" else null
	tr.texture = tex
	tr.visible = tex != null


func _insp_button(parent: Control, label: String, action: String, enabled: bool) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.text = label
	b.disabled = not enabled
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
	if d.has("build_time"):
		lines.append("Workers build it: %.0f work-seconds" % float(d.build_time))
	lines.append("LMB / (A) build    RMB / (B) sell    Esc deselect")
	return "\n".join(lines)


func select(id: String) -> void:
	selected = "" if id == selected else id
	if selected != "" and not selected in CATEGORIES[category]:
		for cat: String in CATEGORIES:
			if selected in CATEGORIES[cat]:
				set_category(cat)
	for k in TOOLS.size():
		_buttons[k].set_pressed_no_signal(TOOLS[k] == selected)
	_info_panel.visible = selected != ""
	if selected != "":
		_info.text = tool_text(selected)
		_set_picture(_info_icon, selected)
	tool_changed.emit(selected)


## Number keys pick within the shown category.
func select_index(k: int) -> void:
	var list: Array = CATEGORIES[category]
	if k >= 0 and k < list.size():
		select(list[k])


func set_category(cat: String) -> void:
	category = cat
	var list: Array = CATEGORIES[cat]
	for k in TOOLS.size():
		_buttons[k].visible = TOOLS[k] in list
		_label_button(k, list)
	for c: String in _cat_buttons:
		_cat_buttons[c].set_pressed_no_signal(c == cat)


func next_category() -> void:
	var keys := CATEGORIES.keys()
	set_category(keys[(keys.find(category) + 1) % keys.size()])


func _cost(id: String) -> int:
	return structures.cost_of(id) if structures else GameConfig.build_cost(id)


## Gamepad LB/RB: step through every tool (switching category as needed).
func cycle(dir: int) -> void:
	var k := TOOLS.find(selected)
	k = wrapi(k + dir, 0, TOOLS.size()) if k >= 0 else (0 if dir > 0 else TOOLS.size() - 1)
	for cat: String in CATEGORIES:
		if TOOLS[k] in CATEGORIES[cat] and cat != category:
			set_category(cat)
	select(TOOLS[k])


func toggle_intel() -> void:
	_intel.visible = not _intel.visible


## Greys out tools you cannot afford.
func refresh_affordability() -> void:
	if economy == null:
		return
	var list: Array = CATEGORIES[category]
	for k in TOOLS.size():
		var ok := economy.can_afford(_cost(TOOLS[k]))
		_buttons[k].modulate = Color.WHITE if ok else Color(1, 1, 1, 0.5)
		if TOOLS[k] in list:
			_label_button(k, list)


## "key  name" and the Biomass cost (green when affordable, red when not).
func _label_button(k: int, list: Array) -> void:
	var id: String = TOOLS[k]
	_btn_name[k].text = "%d  %s" % [list.find(id) + 1, _def(id).get("name", id)]
	var cost := _cost(id)
	_btn_cost[k].text = "%d Biomass" % cost
	var ok := economy == null or economy.can_afford(cost)
	_btn_cost[k].add_theme_color_override("font_color", Color(0.55, 1.0, 0.5) if ok else Color(1.0, 0.5, 0.42))


func toast(text: String) -> void:
	_toast.text = text
	_toast_t = 1.8


func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t, 0.0, 1.0)


## Inspector for a selection. info = {} hides it. info.buttons:
## [{label, action, enabled}] (rebuilt only when they change).
func show_inspector(info: Dictionary) -> void:
	_insp_panel.visible = not info.is_empty()
	if info.is_empty():
		_insp_sig = ""
		return
	_insp_text.text = info.text
	_set_picture(_insp_icon, str(info.get("icon", "")))
	var buttons: Array = info.get("buttons", [])
	var sig := str(buttons)
	if sig == _insp_sig:
		return
	_insp_sig = sig
	for ch in _insp_row.get_children():
		ch.queue_free()
	for b: Dictionary in buttons:
		_insp_button(_insp_row, b.label, b.action, b.get("enabled", true))


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
