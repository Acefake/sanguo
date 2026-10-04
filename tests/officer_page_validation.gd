extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var page = load("res://scenes/officer_page.tscn").instantiate()
	root.add_child(page)
	await process_frame
	assert(page.officers.size() == 18)
	assert(page.tabs.get_child_count() == 4)
	assert(_find_button(page.tabs, "人格") != null)
	assert(page.heading.vertical_alignment == VERTICAL_ALIGNMENT_CENTER)
	var role_kinds := {"军师": "advisor", "主帅": "commander", "前锋": "warrior", "政治": "politics", "外交": "diplomat", "太守": "governor", "参军": "staff"}
	for role in role_kinds:
		assert(page._position_kind(role) == role_kinds[role])
		assert(ResourceLoader.exists("res://assets/officers/position-" + role_kinds[role] + ".png"))
	assert(page._position_kind("都督") == "commander")
	var portrait_paths: Array = []
	for person in page.officers:
		assert(ResourceLoader.exists(person["portrait"]) and ResourceLoader.exists(person["thumbnail"]))
		assert(not person["portrait"] in portrait_paths)
		portrait_paths.append(person["portrait"])
	for i in range(5): assert(int(page.officers[0]["stats"][i]) == [84, 80, 56, 82, 93][i])
	var hovered_officer := _find_button(page.content, "袁尚")
	await _hover(hovered_officer)
	assert(hovered_officer.get_theme_color("icon_hover_color") == Color.WHITE)
	assert(hovered_officer.get_rect().size.x <= 146)
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/officer-list-hover-preview.png")
	await _click(page.tabs.get_child(1))
	assert(page.tab == "人格")
	await _click(_find_button(page.frame, "孙策"))
	assert(page.officers[page.selected]["name"] == "孙策")
	await _click(_find_button(page.frame, "情报一览"))
	assert(page.overview)
	await _click(_find_button(page.frame, "军事"))
	assert(page.sort_column == 0)
	page.overview = false
	page.sort_column = -1
	for person in page.officers:
		assert(person["substats"].size() == 5)
		for group in person["substats"]: assert(group.size() == 5)
	var expected_role_counts := [4, 4, 4, 3, 2, 2, 4, 4, 4, 4, 3, 4, 5, 3, 4, 3, 5, 5]
	for index in page.officers.size():
		page.selected = index
		for name in ["基本", "人格", "关系", "列传"]:
			page.tab = name
			page._render()
			await process_frame
			# 只显示核心位置第一个主图标，其他位置收进悬浮窗。
			var role_icons := 0
			for child in page.content.get_children():
				if child is TextureButton and child.has_meta("position_role"):
					role_icons += 1
					assert(not "不宜位置" in child.tooltip_text)
					assert(child.position.x + child.size.x <= 444)
					assert(child.name == "PrimaryPosition")
			assert(role_icons == (1 if expected_role_counts[index] > 0 else 0))
			if name == "基本" and "--capture" in OS.get_cmdline_user_args():
				await _save("res://assets/officers/portraits/%02d-page.png" % index)
	page.selected = 13
	page.tab = "基本"
	page._render()
	await process_frame
	# 单主图标：次选位置收进主图标悬浮窗，不再有独立图标。
	var alternate_role: TextureButton
	for child in page.content.get_children():
		if child is TextureButton and child.has_meta("position_role"):
			alternate_role = child
			break
	assert(alternate_role != null and "次选位置：偏将" in alternate_role.tooltip_text)
	await _hover(alternate_role)
	assert(alternate_role.is_hovered())
	await create_timer(0.8).timeout
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/position-secondary-tooltip-preview.png")
	page.selected = 0
	page.tab = "基本"
	page._render()
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/basic-preview.png")
	var position_icon: TextureButton
	for child in page.content.get_children():
		if child is TextureButton and not child.tooltip_text.is_empty():
			position_icon = child
			break
	assert(position_icon != null and "核心位置" in position_icon.tooltip_text)
	assert(position_icon.get_meta("position_role") == "君主")
	var zhuge_roles: Array = page._available_positions(page.officers[12])
	assert(zhuge_roles.map(func(role: Dictionary) -> String: return role["name"]) == ["主帅", "军师", "治政", "军需", "参军"])
	var huangzhong_roles: Array = page._available_positions(page.officers[16])
	assert(huangzhong_roles[0]["name"] == "前锋" and huangzhong_roles[0]["source"] == "前锋 105")
	var tooltip = position_icon._make_custom_tooltip(position_icon.tooltip_text)
	assert(tooltip is PanelContainer)
	tooltip.free()
	var icon_motion := InputEventMouseMotion.new()
	icon_motion.position = position_icon.get_global_rect().get_center()
	icon_motion.global_position = icon_motion.position
	root.push_input(icon_motion, true)
	await create_timer(0.8).timeout
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/position-tooltip-preview.png")
	page.overview = true
	for name in ["基本", "个人", "名声", "关系", "属性", "特性"]:
		page.tab = name
		page._render()
		await process_frame
	page.tab = "基本"
	page.sort_column = 0
	page.sort_descending = true
	page._render()
	assert(page.officers[page._filtered()[0]]["name"] == "诸葛亮")
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/intelligence-preview.png")
	# Exercise actual pointer states rather than validating only the normal appearance.
	var hovered_row := _find_row(page.content, "诸葛亮")
	assert(hovered_row != null)
	await _hover(hovered_row)
	assert(hovered_row.is_hovered())
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/intelligence-hover-preview.png")
	await _hover(_find_button(page.content, "谋略"))
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/intelligence-header-hover-preview.png")
	page.filter_text = "袁"
	assert(page._filtered().size() == 4)
	page.faction_filter = "孙吴集团"
	assert(page._filtered().is_empty())
	page.filter_text = ""
	assert(page._filtered().size() == 1)
	page.faction.select(3)
	page.faction.item_selected.emit(3)
	assert(page.faction_filter == "蜀汉集团")
	assert(page._filtered().size() == 10)
	for index in page._filtered():
		var person: Dictionary = page.officers[index]
		assert(not page._traits(person).is_empty())
		for entry in page._traits(person):
			assert(not entry["name"] in ["独有特性", "负面特性", "生涯限制", "效果", "机制"])
		if person["name"] == "诸葛亮":
			for i in range(5): assert(int(person["stats"][i]) == [95, 105, 48, 105, 96][i])
			assert(page._traits(person)[0]["name"] == "卧龙")
			assert(page._trait_rank(page._traits(person)[0]) == "legend")
		if person["name"] == "周仓":
			assert(page._trait_rank(page._traits(person)[2]) == "unranked")
		if person["name"] == "黄忠": assert(page._traits(person).size() == 2)
		if person["name"] == "魏延": assert(page._traits(person).size() == 4)
	if "--capture" in OS.get_cmdline_user_args():
		page._render()
		await _save("res://assets/officers/shuhan-intelligence-preview.png")
		page.overview = false
		page.selected = 12
		page._render()
		await _save("res://assets/officers/shuhan-basic-preview.png")
	page.faction_filter = "全部势力"
	page.faction.select(0)
	page.overview = false
	page.selected = 0
	page.tab = "基本"
	page._render()
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/skills-preview.png")
	var chip := _find_button(page.content, "四世名门")
	assert(chip != null and "名望+3" in chip.tooltip_text)
	assert(page._traits(page.officers[0]).size() == 7)
	await _hover(chip)
	await create_timer(0.8).timeout
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/trait-tooltip-preview.png")
	page.tab = "人格"
	page._render()
	if "--capture" in OS.get_cmdline_user_args(): await _save("res://assets/officers/personality-preview.png")
	page.close_page()
	assert(not page.visible)
	page.open_page(true)
	assert(page.visible and page.overview)
	page.queue_free()
	await process_frame
	print("武将页验证通过：18张人物卡、蜀汉10人、全部分页、特性等级、搜索、势力筛选、排序与返回。")
	quit()

func _save(path: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	assert(root.get_texture().get_image().save_png(path) == OK)

func _find_button(node: Node, value: String) -> Button:
	if node is Button and node.text == value: return node
	for child in node.get_children():
		var result := _find_button(child, value)
		if result != null: return result
	return null

func _find_row(node: Node, name: String) -> Button:
	if node is Button and node.tooltip_text == "查看" + name + "的详细资料": return node
	for child in node.get_children():
		var result := _find_row(child, name)
		if result != null: return result
	return null

func _hover(button: BaseButton) -> void:
	assert(button != null)
	var ancestor := button.get_parent()
	while ancestor != null:
		if ancestor is ScrollContainer: ancestor.ensure_control_visible(button)
		ancestor = ancestor.get_parent()
	await process_frame
	var event := InputEventMouseMotion.new()
	event.position = button.get_global_rect().get_center()
	event.global_position = event.position
	root.push_input(event, true)
	await process_frame

func _click(button: Button) -> void:
	assert(button != null)
	await process_frame
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = button.get_global_rect().get_center()
		event.global_position = event.position
		event.pressed = pressed
		root.push_input(event, true)
	await process_frame
	await process_frame
