class_name BattleTerrain
extends RefCounted
## 战斗地形规则：地形代码到类别与名称、兵种地形系数、进入系数。

static var _rules: Dictionary = {}
static var _table: Dictionary = {}
static func rules() -> Dictionary:
	if _rules.is_empty(): _rules = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))
	return _rules

static func settings(terrain: String, config: Dictionary = {}) -> Dictionary:
	var entries: Dictionary = config.get("terrain", rules().get("terrain", {}))
	return entries.get(terrain, entries.get("plains", {}))

static func table() -> Dictionary:
	if _table.is_empty(): _table = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/terrain_table.json"))
	return _table

static func from_code(code: int) -> String:
	return str(table().get("codes", {}).get(str(code), table().get("default", "plains")))

static func name_of(terrain: String) -> String:
	return str(settings(terrain).get("name", "平原"))

static func unit_factor(type: String, terrain: String, config: Dictionary = {}) -> float:
	var entry := settings(terrain, config)
	return float(entry.get("attack", 1)) * (float(entry.get("cavalry_attack", 1)) if type == "cavalry" else 1.0)

static func entry_factor(army: Dictionary, config: Dictionary = {}) -> float:
	var terrain := str(army.get("tactical", {}).get("terrain_delay", ""))
	if terrain.is_empty(): return 1.0
	# Terrain entry delays apply independently of retired formations.
	return float(settings(terrain, config).get("entry_attack", 1.0))
