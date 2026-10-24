extends Node

var presentation: CanvasLayer

func _ready() -> void:
	presentation = preload("res://scripts/war/presentation/duel_presentation.gd").new()
	add_child(presentation)
	var match_data: Dictionary = preload("res://scripts/war/duel/duel_preview_data.gd").build(get_node("/root/GameState").war)
	var faces: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var portraits: Array = []
	for side in ["left", "right"]:
		var path: String = str(faces.get(str(match_data[side]["name"]), {}).get("thumbnail", ""))
		portraits.append(load(path) if ResourceLoader.exists(path) else null)
	presentation.demo = true
	presentation.present_record(match_data["record"], match_data["left"], match_data["right"], portraits[0], portraits[1])
	presentation.finished.connect(func(): get_tree().quit())
