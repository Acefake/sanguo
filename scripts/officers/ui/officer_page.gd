extends CanvasLayer

signal closed
const OfficerSkin = preload("res://scripts/ui/city_ui_skin.gd")
const Layout = preload("res://scripts/ui/ui_layout.gd")
const Radar = preload("res://scripts/officers/ui/officer_radar.gd")
const TraitButton = preload("res://scripts/officers/ui/officer_trait_button.gd")
const Card = preload("res://scripts/officers/officer_card.gd")
const Traits = preload("res://scripts/officers/trait_registry.gd")
const DIMENSIONS := ["军事", "谋略", "勇武", "政务", "影响"]
const SUB_NAMES := [["统兵", "攻坚", "机动", "奇袭", "治军"], ["智计", "沉着", "料敌", "应变", "辩论"], ["膂力", "体魄", "武艺", "骑术", "射术"], ["农桑", "财赋", "吏治", "法度", "外交"], ["威仪", "仁德", "信义", "名望", "容人"]]
## 特性条的底色：专属金、卓越金、普通银、局限红。
const TRAIT_RANK := {"unique": "legend", "elite": "gold", "common": "silver", "flaw": "negative"}
var officers: Array = []
var selected := 0
var tab := "基本"
var overview := false
var filter_text := ""
var faction_filter := "全部势力"
var sort_column := -1
var sort_descending := true
var frame: Control
var content: Control
var tabs: HBoxContainer
var heading: Label
var search: LineEdit
var faction: OptionButton
var footer: Label

func _ready() -> void:
	officers = []
	for card in JSON.parse_string(FileAccess.get_file_as_string("res://data/officers.json")):
		var view := Card.page_view(card)
		view["traits"] = Card.trait_ids(card).map(func(id): return {"name": str(Traits.definition(id).get("name", id)), "description": str(Traits.definition(id).get("summary", "")), "rank": TRAIT_RANK.get(Traits.tier_of(id), "unranked")})
		officers.append(view)
	frame = Control.new()
	frame.size = Layout.DESIGN
	frame.theme = Theme.new()
	frame.theme.default_font = OfficerSkin.font()
	OfficerSkin.apply_theme(frame.theme)
	frame.theme.set_stylebox("panel", "TooltipPanel", StyleBoxEmpty.new())
	add_child(frame)
	var backdrop := TextureRect.new()
	backdrop.texture = load("res://assets/officers/scene-background.png")
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.position = Vector2.ZERO
	backdrop.size = frame.size
	var blur := ShaderMaterial.new()
	blur.shader = preload("res://shaders/officer_background_blur.gdshader")
	backdrop.material = blur
	frame.add_child(backdrop)
	_sprite(frame, "title-ribbon", Rect2(0, 4, 392, 70))
	heading = _text(frame, "武将资讯", Rect2(42, 4, 340, 70), 36)
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var window := _sprite(frame, "panel-paper", Rect2(58, 82, 1178, 527))
	var window_material := ShaderMaterial.new()
	window_material.shader = preload("res://shaders/officer_window.gdshader")
	window_material.set_shader_parameter("fade_wing", load("res://assets/officers/window-wing.png"))
	window.material = window_material
	_rule(frame, Rect2(164, 82, 966, 1))
	_rule(frame, Rect2(164, 608, 966, 1))
	tabs = HBoxContainer.new()
	tabs.position = Vector2(164, 112)
	tabs.add_theme_constant_override("separation", 5)
	frame.add_child(tabs)
	search = LineEdit.new()
	search.placeholder_text = "查找武将"
	search.position = Vector2(850, 113)
	search.size = Vector2(140, 30)
	search.add_theme_font_size_override("font_size", 13)
	search.text_changed.connect(func(value: String) -> void: filter_text = value; _render())
	frame.add_child(search)
	faction = OptionButton.new()
	faction.position = Vector2(1000, 113)
	faction.size = Vector2(143, 30)
	for value in ["全部势力", "袁绍集团", "曹操集团"]:
		faction.add_item(value)
	OfficerSkin.style_button(faction)
	faction.add_theme_font_size_override("font_size", 14)
	faction.item_selected.connect(func(index: int) -> void: faction_filter = faction.get_item_text(index); _render())
	frame.add_child(faction)
	_rule(frame, Rect2(164, 144, 966, 2))
	content = Control.new()
	content.position = Vector2(164, 146)
	content.size = Vector2(966, 447)
	frame.add_child(content)
	var list_button := _button(frame, "情报一览", Rect2(356, 639, 112, 24), func() -> void: overview = not overview; tab = "基本"; _render())
	_style_footer_button(list_button)
	var source_button := _button(frame, "资料来源", Rect2(468, 639, 112, 24), func() -> void: OS.shell_open(str(officers[selected]["source"])))
	_style_footer_button(source_button)
	var back := _button(frame, "返回", Rect2(620, 620, 62, 62), close_page)
	back.add_theme_stylebox_override("normal", _asset_style("controls", Rect2(14, 13, 132, 132), 0))
	back.add_theme_stylebox_override("hover", _asset_style("controls", Rect2(176, 14, 132, 132), 0))
	back.add_theme_font_size_override("font_size", 19)
	# The octagon plate is dark red; keep the label light like the footer plates.
	for state in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		back.add_theme_color_override(state, OfficerSkin.PALE)
	footer = _text(frame, "", Rect2(915, 88, 215, 25), 15, Color("715d43"))
	get_viewport().size_changed.connect(_resize)
	_resize()
	_render()

func _resize() -> void:
	Layout.fit_center(frame)

func open_page(as_overview := false) -> void:
	overview = as_overview
	tab = "基本"
	_render()
	show()

func close_page() -> void:
	hide()
	closed.emit()

func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_page()
		get_viewport().set_input_as_handled()

func _render() -> void:
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	for child in tabs.get_children():
		tabs.remove_child(child)
		child.queue_free()
	for name in (["基本", "个人", "名声", "关系", "属性", "特性"] if overview else ["基本", "人格", "关系", "列传"]):
		var button := _button(tabs, name, Rect2(0, 0, 59, 31), func() -> void: tab = name; _render())
		button.custom_minimum_size = Vector2(59, 31)
		var tab_style := _extracted_style("tab-active" if name == tab else "tab-normal", 0)
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			button.add_theme_stylebox_override(state, tab_style)
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(state, Color("5f421f"))
	heading.text = "武将情报" if overview else "武将资讯"
	footer.text = "共 %d 位" % _filtered().size()
	search.visible = overview
	faction.visible = overview
	footer.visible = overview
	if overview:
		_render_table()
	else:
		_render_detail()

func _filtered() -> Array:
	var indices: Array = []
	for i in officers.size():
		var person: Dictionary = officers[i]
		if (filter_text.is_empty() or filter_text in str(person["name"]) or filter_text in str(person["style_name"])) and (faction_filter == "全部势力" or faction_filter == person["faction"]):
			indices.append(i)
	if sort_column >= 0:
		indices.sort_custom(func(a: int, b: int) -> bool:
			var av: int = officers[a]["stats"][sort_column]
			var bv: int = officers[b]["stats"][sort_column]
			return av > bv if sort_descending else av < bv)
	return indices

func _render_detail() -> void:
	_panel(content, Rect2(0, 0, 164, 431), _paper_style(0.9))
	_button(content, "武将", Rect2(6, 10, 152, 28), func() -> void: overview = true; tab = "基本"; _render())
	var list := ScrollContainer.new()
	list.position = Vector2(9, 43)
	list.size = Vector2(146, 375)
	list.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_style_scroll(list)
	content.add_child(list)
	# 名单右侧滚动箭头轨道已按需求移除，名单改用原生滚动条。
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 0)
	list.add_child(column)
	for index in _filtered():
		var button := _button(column, str(officers[index]["name"]), Rect2(0, 0, 137, 32), func() -> void: selected = index; _render())
		button.custom_minimum_size = Vector2(137, 32)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.icon = _texture(str(officers[index]["thumbnail"]))
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 21)
		button.add_theme_stylebox_override("normal", _row_style(index == selected))
		button.add_theme_stylebox_override("hover", _row_style(true))
		button.add_theme_stylebox_override("pressed", _row_style(true))
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		_row_separator(button)
		button.add_theme_color_override("font_color", OfficerSkin.INK)
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			button.add_theme_color_override("icon_" + state + "_color", Color.WHITE)
		for state in ["hover", "pressed", "hover_pressed", "focus"]:
			button.add_theme_color_override("font_" + state + "_color", OfficerSkin.INK)
	var person: Dictionary = officers[selected]
	# 收拢中列：立绘加宽并与姓名板、信息框同宽，消除左右空白边缝。
	var portrait := TextureRect.new()
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.position = Vector2(184, 0)
	portrait.size = Vector2(268, 318)
	portrait.texture = load(str(person["portrait"]))
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var portrait_material := ShaderMaterial.new()
	portrait_material.shader = preload("res://shaders/officer_portrait.gdshader")
	portrait.material = portrait_material
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(portrait)
	# 收拢中列：立绘和姓名板直接相接（压到4px内），信息框底部加分隔线压住空旷感。
	_panel(content, Rect2(184, 313, 268, 35), _asset_style("user-title-atlas", Rect2(592, 174, 404, 48), 0))
	_text(content, str(person["name"]), Rect2(196, 318, 130, 25), 23, OfficerSkin.PALE)
	var courtesy := _text(content, str(person["style_name"]), Rect2(342, 318, 95, 25), 22, OfficerSkin.PALE)
	courtesy.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_panel(content, Rect2(184, 348, 268, 93), _paper_style(0.95))
	_field(content, "势力", str(person["faction"]), Rect2(194, 354, 248, 24), 50)
	# P0：忠诚/官职/任官无录入值时直接折叠，不再用破折号占行留白。
	var info_y := 379
	for key in ["忠诚", "官职", "任官"]:
		var info_value := str(person.get(key, person["sections"].get(key, "—")))
		if info_value == "—" or info_value.is_empty():
			continue
		_field(content, key, info_value, Rect2(194, info_y, 248, 22), 50)
		info_y += 23
	_panel(content, Rect2(184, 441, 268, 1), _flat(Color("a99b7e")))
	_position_icons(content, person)
	var right := Control.new()
	right.position = Vector2(456, 0)
	right.size = Vector2(510, 447)
	content.add_child(right)
	match tab:
		"基本": _basic(right, person)
		"人格": _personality_page(right, person)
		"关系": _prose(right, person, ["关系"], "关系与记忆")
		"列传": _prose(right, person, ["定位", "核心定义"], "人物列传")

func _position_icons(parent: Control, person: Dictionary) -> void:
	var positions := str(person["sections"].get("位置", ""))
	var roles := _available_positions(person)
	if roles.is_empty():
		return
	# 只显示核心位置第一个主图标，其他位置收进悬浮窗。
	var primary: Dictionary = roles[0]
	var role_name := str(primary["name"])
	var icon := preload("res://scripts/officers/ui/officer_position_icon.gd").new()
	icon.name = "PrimaryPosition"
	icon.role_name = role_name
	icon.set_meta("primary_position", role_name)
	icon.set_meta("position_role", role_name)
	icon.set_meta("position_group", primary["group"])
	icon.texture_normal = load("res://assets/officers/position-background.png")
	icon.ignore_texture_size = true
	icon.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	icon.position = Vector2(196, 8)
	icon.size = Vector2(32, 32)
	var lines: Array[String] = []
	for role in roles:
		var entry := str(role["group"]) + "：" + str(role["source"])
		if entry != role_name and not entry in lines:
			lines.append(entry)
	icon.tooltip_text = role_name + "\n" + "\n".join(lines)
	icon.mouse_default_cursor_shape = Control.CURSOR_HELP
	icon.mouse_entered.connect(func() -> void: icon.modulate = Color(1.08, 1.08, 1.08))
	icon.mouse_exited.connect(func() -> void: icon.modulate = Color.WHITE)
	parent.add_child(icon)
	var glyph := TextureRect.new()
	glyph.texture = load("res://assets/officers/position-" + _position_kind(role_name) + ".png")
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.position = Vector2(6, 6)
	glyph.size = Vector2(20, 20)
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.add_child(glyph)
	_panel(parent, Rect2(icon.position + Vector2(-6, 33), Vector2(44, 15)), _flat(Color("eee7d3")))
	var caption := _text(parent, role_name.split("（")[0], Rect2(icon.position + Vector2(-6, 33), Vector2(44, 15)), 13)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _available_positions(person: Dictionary) -> Array:
	var result: Array = []
	var score_suffix := RegEx.new()
	score_suffix.compile("\\s+\\d+(?:\\.\\d+)?$")
	for line in str(person["sections"].get("位置", "")).split("\n"):
		if not "：" in line: continue
		var parts := line.split("：", true, 1)
		var group := parts[0].strip_edges()
		if not group in ["核心位置", "次选位置"]: continue
		for item in parts[1].replace("｜", "、").replace("，", "、").split("、"):
			var source := item.strip_edges()
			var role_name := score_suffix.sub(source, "").strip_edges()
			if role_name.is_empty() or role_name in ["—", "无", "无。"]: continue
			var duplicate := false
			for entry in result:
				if entry["name"] == role_name: duplicate = true; break
			if not duplicate: result.append({"name": role_name, "group": group, "source": source})
	return result

func _position_kind(primary: String) -> String:
	if "军师" in primary or "谋" in primary: return "advisor"
	if "君主" in primary or "领袖" in primary or "都督" in primary or "主帅" in primary or "副帅" in primary: return "commander"
	if "太守" in primary: return "governor"
	if "参军" in primary: return "staff"
	if "外交" in primary or "使" in primary or "谈判" in primary or "联盟" in primary: return "diplomat"
	if "政" in primary or "内务" in primary or "文官" in primary or "军需" in primary or "财政" in primary or "人事" in primary: return "politics"
	if "将" in primary or "锋" in primary or "战" in primary or "亲兵" in primary or "护卫" in primary or "护军" in primary or "奇兵" in primary or "殿后" in primary: return "warrior"
	return "staff"

func _personality_page(parent: Control, person: Dictionary) -> void:
	# 右侧纸面背景已按需求移除，内容直接落在窗口纸底上。
	_section_title(parent, "人格", 10)
	_panel(parent, Rect2(8, 44, 494, 1), _flat(Color("a99b7e")))
	var index := 0
	for name in _personality(person):
		var x := 16 + (index % 3) * 164
		var y := 60 + (index / 3) * 67
		var ink := Radar.OVERFLOW_BLUE if float(_personality(person)[name]) > 100 else OfficerSkin.INK
		_text(parent, name, Rect2(x, y, 106, 19), 16, ink)
		var value := _text(parent, str(_personality(person)[name]), Rect2(x + 107, y, 36, 19), 16, ink)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_meter(parent, Rect2(x, y + 26, 143, 4), float(_personality(person)[name]))
		index += 1

func _basic(parent: Control, person: Dictionary) -> void:
	_skills(parent, person)
	var radar := Radar.new()
	radar.position = Vector2(173, 2)
	radar.size = Vector2(230, 174)
	radar.theme = frame.theme
	radar.values = person["stats"]
	parent.add_child(radar)

func _meter(parent: Control, rect: Rect2, value: float) -> void:
	# 修复：右侧纸底移除后轨道对比度不足，深色描边打底、加深轨道、填充提饱和。
	var outer := Rect2(rect.position - Vector2(1, 1), Vector2(rect.size.x + 2, 7))
	_panel(parent, outer, _flat(Color("7d6c4e")))
	var track := Rect2(rect.position, Vector2(rect.size.x, 5))
	_panel(parent, track, _flat(Color("b3a586")))
	var amount := clampf(value / 100.0, 0.0, 1.0)
	_panel(parent, Rect2(track.position, Vector2(track.size.x * amount, track.size.y)), _flat(Radar.OVERFLOW_BLUE if value > 100 else Color("8a6a24")))

func _skills(parent: Control, person: Dictionary) -> void:
	# 右侧纸面背景已按需求移除，内容直接落在窗口纸底上。
	_section_title(parent, "能力", 10)
	_section_title(parent, "子能力", 178)
	_section_title(parent, "特性", 326)
	for y in [174, 316, 422]:
		_panel(parent, Rect2(8, y, 494, 1), _flat(Color("a99b7e")))
	for i in range(5):
		var y := 179 + i * 26
		var category := _text(parent, DIMENSIONS[i], Rect2(96, y, 40, 20), 15, Color("8c5c3d"))
		category.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		category.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		for j in range(5):
			var x := 144 + j * 71
			var ink := Radar.OVERFLOW_BLUE if float(person["substats"][i][j]) > 100 else OfficerSkin.INK
			# P1：名称左对齐、数值右对齐到固定列宽，解决原来列宽随数字抖动的问题。
			var attribute := _text(parent, SUB_NAMES[i][j], Rect2(x, y, 34, 20), 15, ink)
			attribute.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			var value := _text(parent, str(int(person["substats"][i][j])), Rect2(x + 34, y, 30, 20), 15, ink)
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			_meter(parent, Rect2(x, y + 21, 64, 4), float(person["substats"][i][j]))
	_trait_chips(parent, person, Rect2(96, 326, 398, 88))

func _section_title(parent: Control, title: String, y: float) -> void:
	_panel(parent, Rect2(8, y, 76, 26), _asset_style("user-title-atlas", Rect2(130, 66, 517, 52), 0))
	var label := _text(parent, title, Rect2(8, y, 76, 26), 18, Color("d3b568"))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func _traits(person: Dictionary) -> Array:
	return person.get("traits", [])

func _trait_chips(parent: Control, person: Dictionary, rect: Rect2) -> void:
	var traits := _traits(person)
	if traits.is_empty():
		_text(parent, "尚未录入特性", rect, 16)
		return
	# P2：特性改为自动换行（两行兜底），不再单行硬排被面板裁掉。
	var strip := Control.new()
	strip.position = rect.position
	strip.size = Vector2(rect.size.x, rect.size.y)
	strip.clip_contents = true
	parent.add_child(strip)
	var per_row := mini(5, maxi(1, int((rect.size.x + 6) / 78.0)))
	var rows := maxi(1, int(ceil(traits.size() / float(per_row))))
	var row_height := minf(25.0, rect.size.y / float(maxi(rows, 1)))
	var chip_width := minf(72.0, (rect.size.x - (per_row - 1) * 6) / per_row)
	for i in traits.size():
		var entry: Dictionary = traits[i]
		var chip := TraitButton.new()
		chip.theme = frame.theme
		chip.text = entry["name"]
		chip.tooltip_text = entry["description"]
		chip.mouse_default_cursor_shape = Control.CURSOR_HELP
		var rank := _trait_rank(entry)
		var row := i / per_row
		var col := i % per_row
		chip.position = Vector2(col * (chip_width + 6), row * row_height + 2)
		chip.size = Vector2(chip_width, 21)
		chip.add_theme_font_size_override("font_size", 12)
		for state in ["normal", "hover", "pressed", "disabled", "hover_pressed"]:
			var style := _trait_style(rank, state != "normal")
			chip.add_theme_stylebox_override(state, style)
		chip.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		chip.add_theme_color_override("font_color", OfficerSkin.PALE)
		chip.add_theme_color_override("font_hover_color", OfficerSkin.PALE)
		chip.add_theme_color_override("font_pressed_color", OfficerSkin.PALE)
		strip.add_child(chip)

func _trait_rank(entry: Dictionary) -> String:
	return str(entry.get("rank", "unranked"))

## 缺立绘的人物（官渡新卡多数还没有头像）返回 null，不报加载错误。
func _texture(path: String) -> Texture2D:
	return load(path) if not path.is_empty() and ResourceLoader.exists(path) else null

func _trait_style(kind: String, hovered: bool) -> StyleBoxTexture:
	var asset := "trait-common" if kind == "unranked" else "personality-gold" if kind == "legend" else "personality-" + kind
	var style := _extracted_style(asset, 5)
	if hovered: style.modulate_color = Color(1.15, 1.15, 1.15)
	return style

func _prose(parent: Control, person: Dictionary, keys: Array, title: String, fallback := "") -> void:
	# 右侧纸面背景已按需求移除，内容直接落在窗口纸底上。
	_section_title(parent, title, 10)
	_panel(parent, Rect2(8, 44, 494, 1), _flat(Color("a99b7e")))
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(15, 55)
	scroll.size = Vector2(484, 376)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_style_scroll(scroll)
	parent.add_child(scroll)
	var label := OfficerSkin.label("", 16)
	label.custom_minimum_size.x = 464
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if keys.is_empty():
		label.text = preload("res://scripts/ui/ui_text.gd").clean(fallback)
	else:
		# 列传去掉「定位」「核心定义」这类说明标题，只拼正文。
		var parts: Array[String] = []
		for key in keys:
			parts.append(str(person["sections"].get(key, "尚未录入")))
		label.text = preload("res://scripts/ui/ui_text.gd").clean("\n\n".join(parts))
	scroll.add_child(label)

func _render_table() -> void:
	_panel(content, Rect2(0, 0, 966, 431), _paper_style(0.94))
	var headers: Array = ["武将", "所属", "军事", "谋略", "勇武", "政治", "魅力"]
	if tab == "个人": headers = ["武将", "所属", "字"]
	if tab == "名声": headers = ["武将", "所属", "名望"]
	if tab in ["关系", "属性", "特性"]: headers = ["武将", "所属", "资料"]
	# Compact table columns leave the unused right-hand paper visible, as in the reference.
	var header_style := _extracted_style("table-header", 0)
	header_style.texture_margin_left = 16
	header_style.texture_margin_right = 16
	header_style.texture_margin_top = 0
	header_style.texture_margin_bottom = 0
	_panel(content, Rect2(10, 10, 612, 28), header_style)
	for i in headers.size():
		var x := 10 if i == 0 else (166 if i == 1 else 292 + (i - 2) * 66)
		var width := 156 if i == 0 else (126 if i == 1 else (330 if headers.size() == 3 else 66))
		if i > 0:
			_panel(content, Rect2(x, 12, 1, 24), _flat(Color("e9d9ad")))
		var button := _button(content, str(headers[i]), Rect2(x, 10, width, 28), func() -> void:
			if tab == "基本" and i >= 2:
				if sort_column == i - 2: sort_descending = not sort_descending
				else: sort_column = i - 2; sort_descending = true
				_render())
		button.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		button.add_theme_stylebox_override("hover", _extracted_style("table-header-hover", 0))
		button.add_theme_stylebox_override("pressed", _extracted_style("table-header-hover", 0))
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.add_theme_color_override("font_hover_color", OfficerSkin.INK)
		button.add_theme_color_override("font_pressed_color", OfficerSkin.INK)
		if tab == "基本" and i - 2 == sort_column and i >= 2: button.text += " ↓" if sort_descending else " ↑"
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(10, 50)
	scroll.size = Vector2(948, 370)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_style_scroll(scroll)
	content.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 0)
	scroll.add_child(column)
	for index in _filtered():
		var person: Dictionary = officers[index]
		var row := _button(column, "", Rect2(0, 0, 934, 32), func() -> void: selected = index; overview = false; tab = "基本"; _render())
		row.custom_minimum_size = Vector2(930, 32)
		row.add_theme_stylebox_override("normal", _row_style(index == selected))
		row.add_theme_stylebox_override("hover", _row_style(true))
		row.add_theme_stylebox_override("pressed", _row_style(true))
		row.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		_row_separator(row)
		row.tooltip_text = "查看" + str(person["name"]) + "的详细资料"
		var thumbnail := TextureRect.new()
		thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumbnail.texture = _texture(str(person["thumbnail"]))
		thumbnail.position = Vector2(28, 4)
		thumbnail.size = Vector2(23, 23)
		thumbnail.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(thumbnail)
		_text(row, str(person["name"]), Rect2(57, 4, 101, 26), 20)
		var faction_label := _text(row, str(person["faction"]), Rect2(156, 5, 126, 24), 17)
		faction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var values: Array = person["stats"]
		if tab == "个人": values = [person["style_name"]]
		if tab == "名声": values = [person["substats"][4][3]]
		if tab == "关系": values = ["%d 条有向关系" % str(person["sections"].get("关系", "")).split("\n", false).size()]
		if tab == "属性": values = ["25项子属性  点击查看"]
		if tab == "特性":
			values = []
			_trait_chips(row, person, Rect2(282, 2, 650, 30))
		for i in values.size():
			var value := str(int(values[i])) if values[i] is float else str(values[i])
			var value_label := _text(row, value, Rect2(282 + i * 66, 5, 650 if values.size() == 1 else 66, 24), 18)
			if tab in ["基本", "名声"] and float(values[i]) > 100:
				value_label.add_theme_color_override("font_color", Radar.OVERFLOW_BLUE)
			if values.size() > 1: value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if _filtered().is_empty(): _text(content, "没有符合条件的武将", Rect2(290, 180, 450, 40), 24)

func _text(parent: Node, value: String, rect: Rect2, font_size := 18, color := OfficerSkin.INK) -> Label:
	var label := OfficerSkin.label(value, maxi(11, roundi(font_size * 0.88) - 1), color)
	label.clip_text = true
	label.position = rect.position
	label.size = rect.size
	parent.add_child(label)
	return label

func _panel(parent: Node, rect: Rect2, style: StyleBox) -> Panel:
	var panel := Panel.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	return panel

func _rule(parent: Node, rect: Rect2) -> void:
	var line := TextureRect.new()
	line.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	line.texture = load("res://assets/officers/rule.png")
	line.position = rect.position
	line.size = rect.size
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(line)

func _button(parent: Node, value: String, rect: Rect2, callback: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.position = rect.position
	button.size = rect.size
	button.add_theme_font_size_override("font_size", 15)
	OfficerSkin.style_button(button)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _flat(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	return style

func _style_footer_button(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxTexture.new()
		var asset := "command-red" if state == "normal" else ("command-disabled" if state == "disabled" else "command-hover")
		style.texture = load("res://assets/city/han/ui/user-atlas/" + asset + ".png")
		style.set_texture_margin_all(2)
		style.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, style)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_font_size_override("font_size", 14)
	# The command plate is a dark red, so the shared theme's dark INK was
	# unreadable in the normal state. Every state now uses the light paper tone.
	for state in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		button.add_theme_color_override(state, OfficerSkin.PALE)

func _row_style(active: bool) -> StyleBox:
	# P3：选中行改用加深底色，不再依赖难以分辨的浅黄高亮图。
	if active:
		var selected := _flat(Color("e3c878"))
		selected.content_margin_left = 3
		return selected
	var style := _flat(Color(1, 1, 1, 0))
	return style

func _row_separator(row: Control) -> void:
	var line := Panel.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	line.offset_top = -1
	line.offset_bottom = 0
	line.add_theme_stylebox_override("panel", _flat(Color("aaa08c")))
	row.add_child(line)

func _sprite(parent: Node, asset: String, rect: Rect2) -> TextureRect:
	var sprite := TextureRect.new()
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.texture = load("res://assets/officers/" + asset + ".png")
	sprite.position = rect.position
	sprite.size = rect.size
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(sprite)
	return sprite

func _extracted_style(asset: String, margin: int) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = load("res://assets/officers/" + asset + ".png")
	style.set_texture_margin_all(margin)
	style.set_content_margin_all(0)
	return style

func _paper_style(alpha: float) -> StyleBoxTexture:
	var style := _extracted_style("panel-paper", 0)
	style.modulate_color = Color(1, 1, 1, alpha)
	return style

func _field(parent: Node, name: String, value: String, rect: Rect2, label_width: int) -> void:
	_text(parent, name, Rect2(rect.position, Vector2(label_width, rect.size.y)), 17, Color("8c5c3d"))
	var label := _text(parent, value, Rect2(rect.position + Vector2(label_width, 0), Vector2(rect.size.x - label_width - 3, rect.size.y)), 17)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.tooltip_text = value

func _positions(person: Dictionary) -> Array:
	var result: Array = ["—", "—", "—"]
	var lines: PackedStringArray = str(person["sections"].get("位置", "")).split("\n")
	for i in mini(3, lines.size()):
		if "：" in lines[i]:
			result[i] = lines[i].split("：", true, 1)[1].split("、")[0]
	return result

func _personality(person: Dictionary) -> Dictionary:
	var result := {}
	var pattern := RegEx.new()
	pattern.compile("([\\p{Han}]+)\\s*(\\d+)")
	for match_result in pattern.search_all(str(person["sections"].get("人格数值", ""))):
		result[match_result.get_string(1)] = match_result.get_string(2)
	return result

func _style_scroll(scroll: ScrollContainer) -> void:
	var bar := scroll.get_v_scroll_bar()
	var track := _flat(Color("938a77"))
	track.content_margin_left = 4
	track.content_margin_right = 4
	bar.add_theme_stylebox_override("scroll", track)
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		bar.add_theme_stylebox_override(state, _extracted_style("scroll-thumb", 3))

func _scroll_arrows(parent: Node, scroll: ScrollContainer, rect: Rect2) -> void:
	for up in [true, false]:
		var button := TextureButton.new()
		button.texture_normal = load("res://assets/officers/scroll-up.png" if up else "res://assets/officers/scroll-down.png")
		button.ignore_texture_size = true
		button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button.position = rect.position if up else rect.position + Vector2(0, rect.size.y - 16)
		button.size = Vector2(rect.size.x, 16)
		button.pressed.connect(func() -> void: scroll.scroll_vertical = maxi(0, scroll.scroll_vertical + (-96 if up else 96)))
		parent.add_child(button)
		button.hide()
		var bar := scroll.get_v_scroll_bar()
		var update_visibility := func() -> void: button.visible = bar.max_value > bar.page
		bar.changed.connect(update_visibility)
		update_visibility.call_deferred()

func _asset_style(asset: String, region: Rect2, margin: int) -> StyleBoxTexture:
	var texture := AtlasTexture.new()
	texture.atlas = load("res://assets/officers/" + asset + ".png")
	texture.region = region
	var style := StyleBoxTexture.new()
	style.texture = texture
	style.set_texture_margin_all(margin)
	return style

