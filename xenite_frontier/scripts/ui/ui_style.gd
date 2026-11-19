class_name UiStyle
extends RefCounted
## Shared colony-terminal look. Sizes chosen for 1280x800 (Steam Deck).

const ALIEN_COLORS := {
	"stalker": "#dcc775", "mauler": "#c0301a", "spitter": "#73ff33",
	"snatcher": "#8a44e0", "burrower": "#eb8c24", "brood_mother": "#e01a72",
}


static func panel(alpha := 0.82, border := Color(0.2, 0.75, 0.9, 0.6)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.05, alpha)
	sb.border_color = border
	sb.border_width_left = 2
	sb.content_margin_left = 10; sb.content_margin_right = 10
	sb.content_margin_top = 6; sb.content_margin_bottom = 6
	return sb


static func theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 17
	return t


static func alien_color(id: String) -> String:
	return ALIEN_COLORS.get(id, "#ffffff")
