extends Node
## Autoload: loads every data file once so systems read tuning from JSON,
## never from hard-coded constants. Also derives the damage counter matrix.

const ALIENS_PATH := "res://data/aliens.json"
const TURRETS_PATH := "res://data/turrets.json"
const STRUCTURES_PATH := "res://data/structures.json"
const CONFIG_PATH := "res://data/game_config.json"

enum Dmg { BALLISTIC, INCENDIARY, PIERCING, SHOCK, EXPLOSIVE, SEISMIC }
const DMG_COUNT := 6

var alien_defs: Array = []      # index == alien type id
var turret_defs: Array = []
var structure_defs: Array = []
var structures: Dictionary = {}
var turrets_data: Dictionary = {}
var config: Dictionary = {}
var damage_type_ids: PackedStringArray = []
## damage multiplier: counter[alien_type * DMG_COUNT + damage_type]
var counter := PackedFloat32Array()


func _ready() -> void:
	reload()
	InputSetup.ensure_defaults()


func reload() -> void:
	alien_defs = load_json(ALIENS_PATH).get("aliens", [])
	turrets_data = load_json(TURRETS_PATH)
	turret_defs = turrets_data.get("turrets", [])
	structures = load_json(STRUCTURES_PATH)
	structure_defs = structures.get("structures", [])
	config = load_json(CONFIG_PATH)
	damage_type_ids = PackedStringArray(turrets_data.get("damage_types", []))
	_build_counter()


func _build_counter() -> void:
	var weak := float(turrets_data.get("weak_multiplier", 1.5))
	var resist := float(turrets_data.get("resist_multiplier", 0.5))
	counter.resize(alien_defs.size() * DMG_COUNT)
	counter.fill(1.0)
	for a in alien_defs.size():
		for d in DMG_COUNT:
			var id := damage_type_ids[d]
			if id in alien_defs[a].get("weak", []):
				counter[a * DMG_COUNT + d] = weak
			elif id in alien_defs[a].get("resists", []):
				counter[a * DMG_COUNT + d] = resist


func section(name: String) -> Dictionary:
	return config.get(name, {})


func alien_index(id: String) -> int:
	for i in alien_defs.size():
		if alien_defs[i].id == id:
			return i
	return -1


func damage_index(id: String) -> int:
	return damage_type_ids.find(id)


func damage_name(d: int) -> String:
	return turrets_data.get("damage_type_names", {}).get(damage_type_ids[d], damage_type_ids[d])


func damage_color(d: int) -> Color:
	return Color(turrets_data.get("damage_type_colors", {}).get(damage_type_ids[d], "#ffffff"))


func multiplier(alien_type: int, dmg: int) -> float:
	return counter[alien_type * DMG_COUNT + dmg]


## Tooltip text for a damage type: who it counters and who shrugs it off.
func counter_summary(dmg: int) -> String:
	var strong: PackedStringArray = []
	var weak: PackedStringArray = []
	for a in alien_defs.size():
		var m := multiplier(a, dmg)
		if m > 1.0:
			strong.append(alien_defs[a].name)
		elif m < 1.0:
			weak.append(alien_defs[a].name)
	var s := "Strong vs: %s (150%%)" % (", ".join(strong) if not strong.is_empty() else "-")
	s += "\nPoor vs: %s (50%%)" % (", ".join(weak) if not weak.is_empty() else "-")
	return s


static func load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("GameConfig: cannot open %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("GameConfig: %s is not a JSON object" % path)
	return {}
