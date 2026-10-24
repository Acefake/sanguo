extends Node

# Preview the same map-local effect used by actual battles.
var presentation: CanvasLayer

func _ready() -> void:
	var map_scene := preload("res://scenes/rtk14_world_3d.tscn").instantiate()
	add_child(map_scene)
	await get_tree().process_frame
	map_scene.army_world.preview_duel()
	presentation = map_scene.army_world.duel_presentation
	var center: Vector3 = (presentation.source + presentation.target) * 0.5
	map_scene.target_goal = center
	map_scene.camera_target = center
	map_scene.distance = 25.0
	map_scene.distance_goal = 25.0
	map_scene._update_camera()
