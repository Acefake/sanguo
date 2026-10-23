extends SceneTree
## 离线生成「选择战场」卡片缩略图：逐个载入独立战场，隐藏全部界面层，按开战镜头截图，
## 裁成 16:9 缩放到 480×270，写入 res://assets/ui/battle_thumbs/<场景 id>.png。
##
## 用法：godot --path . --resolution 1280x720 --script res://tools/capture/capture_battle_thumbs.gd [-- --only=<id>]
## 需要真实渲染（不能 --headless）。缩略图只是贴图，重新生成不影响任何规则数据。

const Scenarios = preload("res://scripts/war/battle/battle_scenarios.gd")
const OUT_DIR := "res://assets/ui/battle_thumbs/"
const SIZE := Vector2i(480, 270)
const SETTLE_FRAMES := 45


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="): only = arg.trim_prefix("--only=")
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for spec in Scenarios.definitions():
		var id: String = spec["id"]
		if not only.is_empty() and id != only: continue
		store.prepare_battle_test(true, id, 1910901)
		var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
		root.add_child(scene)
		while not scene.loaded: await process_frame
		for layer in scene.find_children("*", "CanvasLayer", true, false): layer.visible = false
		for i in SETTLE_FRAMES: await process_frame
		await RenderingServer.frame_post_draw
		var path := OUT_DIR + id + ".png"
		var error := _thumbnail(root.get_texture().get_image()).save_png(path)
		print("THUMB %s %s" % [id, "ok" if error == OK else "error %d" % error])
		scene.queue_free()
		await process_frame
	store.restore_battle_test()
	quit(0)


## 居中裁成 16:9 再缩放，避免窗口比例不同时缩略图被拉伸。
func _thumbnail(image: Image) -> Image:
	var width := image.get_width()
	var height := image.get_height()
	var crop_height := mini(height, int(width * 9.0 / 16.0))
	var crop_width := int(crop_height * 16.0 / 9.0)
	var region := Rect2i((width - crop_width) / 2, (height - crop_height) / 2, crop_width, crop_height)
	var result := image.get_region(region)
	result.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	return result
