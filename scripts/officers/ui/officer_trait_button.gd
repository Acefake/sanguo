extends Button

func _make_custom_tooltip(description: String) -> Object:
	var panel := PanelContainer.new()
	panel.theme = theme
	var style := StyleBoxFlat.new()
	style.bg_color = Color("eee7d3")
	style.border_color = Color("b5a27c")
	style.set_border_width_all(1)
	style.shadow_color = Color(0.12, 0.10, 0.07, 0.2)
	style.shadow_size = 4
	style.shadow_offset = Vector2(0, 2)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 7)
	panel.add_child(column)
	var title := Label.new()
	title.text = text
	title.add_theme_color_override("font_color", Color("805638"))
	title.add_theme_font_size_override("font_size", 15)
	column.add_child(title)
	var label := Label.new()
	var body := description
	while body.begins_with(text + "\n"):
		body = body.trim_prefix(text + "\n")
	if body.begins_with(text + "："): body = body.trim_prefix(text + "：")
	elif not "\n" in description and "：" in body: body = body.split("：", true, 1)[1]
	label.text = preload("res://scripts/ui/ui_text.gd").clean(body.replace("；", "；\n"))
	label.custom_minimum_size.x = 300
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color("423b2c"))
	label.add_theme_font_size_override("font_size", 13)
	column.add_child(label)
	return panel
