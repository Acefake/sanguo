extends SceneTree
func _initialize() -> void:
    call_deferred("capture")
func capture() -> void:
    var map = load("res://scenes/map_slice.tscn").instantiate()
    root.add_child(map)
    map.set_process_unhandled_input(false)
    map.hovered_id = "luoyang"
    map.camera.position = map._place_position("luoyang")
    map.camera.zoom = Vector2(2, 2)
    map.queue_redraw()
    await create_timer(0.5).timeout
    await RenderingServer.frame_post_draw
    root.get_texture().get_image().save_png("res://assets/map/supplied/shield-refined-preview.png")
    quit()
