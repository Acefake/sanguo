extends Node

var presentation: CanvasLayer

func _ready() -> void:
	presentation = preload("res://scripts/war/presentation/duel_presentation.gd").new()
	add_child(presentation)
	var faces: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var left_face: Texture2D = null
	var right_face: Texture2D = null
	for pair in [["张辽", 0], ["颜良", 1]]:
		var path: String = str(faces.get(pair[0], {}).get("thumbnail", ""))
		if ResourceLoader.exists(path):
			if pair[1] == 0: left_face = load(path)
			else: right_face = load(path)
	presentation.demo = true
	var match_data: Dictionary = preload("res://scripts/war/duel/duel_preview_data.gd").build(get_node("/root/GameState").war)
	presentation.present_record(match_data["record"], match_data["left"], match_data["right"], left_face, right_face)
	presentation.finished.connect(func(): get_tree().quit())
