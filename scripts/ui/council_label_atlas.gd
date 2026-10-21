extends RefCounted

const SOURCE := "res://assets/city/han/ui/user-atlas/council-labels.png"
const MANIFEST := "res://assets/city/han/ui/user-atlas/council-labels-regions.json"
const CANVAS := Vector2(290, 120)
static var _regions: Dictionary = {}
static var _textures: Dictionary = {}


static func texture(key: String, state: int) -> AtlasTexture:
	if _regions.is_empty():
		_regions = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	var cache_key := key + str(state)
	if not _textures.has(cache_key):
		var area: Array = _regions[key][state]
		var result := AtlasTexture.new()
		result.atlas = load(SOURCE)
		result.region = Rect2(area[0], area[1], area[2], area[3])
		var padding := CANVAS - result.region.size
		result.margin = Rect2(padding * 0.5, padding)
		result.filter_clip = true
		_textures[cache_key] = result
	return _textures[cache_key]


static func apply(button: Button, key: String, selected: bool = false) -> void:
	button.text = ""
	button.icon = null
	button.set_meta("lettering_selected", selected)
	var lettering := button.get_node_or_null("CouncilLettering") as Lettering
	if lettering == null:
		lettering = Lettering.new()
		lettering.name = "CouncilLettering"
		lettering.button = button
		lettering.key = key
		lettering.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lettering.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lettering.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lettering.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		lettering.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lettering.offset_left = 6
		lettering.offset_right = -6
		lettering.offset_top = 2
		lettering.offset_bottom = -2
		button.add_child(lettering)
	lettering.show()
	lettering.refresh()


static func clear(button: Button, caption: String) -> void:
	var lettering := button.get_node_or_null("CouncilLettering")
	if lettering != null:
		lettering.hide()
	button.text = caption


class Lettering extends TextureRect:
	var button: Button
	var key: String
	var last_state := -1

	func _process(_delta: float) -> void:
		refresh()

	func refresh() -> void:
		var state := 0
		if button.disabled:
			state = 3
		elif button.is_pressed():
			state = 2
		elif button.is_hovered():
			state = 1
		elif bool(button.get_meta("lettering_selected", false)):
			state = 2
		if state != last_state:
			texture = texture_for_state(state)
			last_state = state

	func texture_for_state(state: int) -> Texture2D:
		return load("res://scripts/ui/council_label_atlas.gd").texture(key, state)
