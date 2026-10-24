extends SceneTree

const Atlas = preload("res://scripts/ui/ui_sprite_atlas.gd")
const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")


func _initialize() -> void:
	var source := load(Atlas.SOURCE) as Texture2D
	for key in Atlas.REGIONS:
		assert(Rect2i(Vector2i.ZERO, source.get_size()).encloses(Atlas.REGIONS[key]), "切片越界：" + key)
		var texture := Atlas.texture(key)
		assert(texture == Atlas.texture(key), "切片未缓存：" + key)
		var pixels := texture.get_image()
		if key.begins_with("button_") or key.begins_with("octagon_") or key.begins_with("token_"):
			assert(pixels.get_pixel(0, 0).a == 0.0, "按钮角落存在底色：" + key)
			var center := Vector2i(pixels.get_width() / 2, pixels.get_height() / 2)
			assert(pixels.get_pixelv(center).a == (0.0 if key.ends_with("_outline") else 1.0), "按钮内部透明度错误：" + key)
	var dark_pixels := Atlas.texture("dark_panel").get_image()
	assert(dark_pixels.get_pixel(40, 15).a == 1.0, "深色面板内部被错误去底")
	var focus_pixels := Atlas.texture("focus_gold").get_image()
	assert(focus_pixels.get_pixel(90, 33).a == 0.0, "焦点边框遮住按钮内容")
	var button := Button.new()
	CitySkin.style_button(button)
	assert(button.get_theme_stylebox("normal").texture != button.get_theme_stylebox("hover").texture)
	assert(button.get_theme_stylebox("normal").texture != button.get_theme_stylebox("disabled").texture)
	CitySkin.style_confirm_button(button)
	assert(button.get_theme_stylebox("normal").texture == Atlas.texture("octagon_red"))
	button.free()
	print("精灵图检查通过：切片范围、缓存、透明边缘、深色按钮、焦点镂空与状态切换正确。")
	quit(0)
