extends Node
## Autoload: loads every data file once so systems read tuning from JSON,
## never from hard-coded constants.

const ALIENS_PATH := "res://data/aliens.json"
const CONFIG_PATH := "res://data/game_config.json"

var alien_defs: Array = []      # index == alien type id
var config: Dictionary = {}


func _ready() -> void:
	reload()
	InputSetup.ensure_defaults()


func reload() -> void:
	var a := load_json(ALIENS_PATH)
	alien_defs = a.get("aliens", [])
	config = load_json(CONFIG_PATH)


func section(name: String) -> Dictionary:
	return config.get(name, {})


func alien_index(id: String) -> int:
	for i in alien_defs.size():
		if alien_defs[i].id == id:
			return i
	return -1


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
