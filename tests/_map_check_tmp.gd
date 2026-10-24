extends SceneTree

# Throwaway check that aspect="expand" plus the larger default window does not
# break the 2D strategic map framing. Writes to user:// only.
const OUT := "user://map-expand.png"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var map = load("res://scenes/map_slice.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	await create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	print("viewport:", root.get_visible_rect().size)
	var image := root.get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path(OUT))
	print("SAVED:", ProjectSettings.globalize_path(OUT))
	quit(0)