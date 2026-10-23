extends RefCounted

# These circular icons already contain their symbols and transparent edges.
const SOURCE := "res://assets/city/han/ui/user-atlas/toolbar-source.png"
const REGIONS := {
	6: [Rect2(1488, 344, 100, 100), Rect2(1602, 344, 100, 100), Rect2(1716, 344, 100, 100), Rect2(1830, 344, 100, 100)],
	7: [Rect2(804, 238, 100, 100), Rect2(918, 344, 100, 100), Rect2(1032, 344, 100, 100), Rect2(1146, 344, 100, 100)],
	8: [Rect2(690, 124, 100, 100), Rect2(918, 230, 100, 100), Rect2(1146, 230, 100, 100), Rect2(1032, 230, 100, 100)],
	9: [Rect2(234, 352, 100, 100), Rect2(348, 352, 100, 100), Rect2(462, 352, 100, 100), Rect2(576, 352, 100, 100)],
	10: [Rect2(6, 124, 100, 100), Rect2(120, 124, 100, 100), Rect2(234, 124, 100, 100), Rect2(348, 124, 100, 100)],
	11: [Rect2(120, 238, 100, 100), Rect2(234, 238, 100, 100), Rect2(348, 238, 100, 100), Rect2(462, 238, 100, 100)],
}
static var _textures: Dictionary = {}


static func texture(index: int, state: int = 0) -> AtlasTexture:
	var key := Vector2i(index, state)
	if not _textures.has(key):
		var result := AtlasTexture.new()
		result.atlas = load(SOURCE)
		if state == 4:
			result.region = Rect2(0, 0, 120, 120)
		else:
			var bounds: Rect2 = REGIONS[index][state]
			# The 100 px nominal cell excludes the rim and lower shadow. Add
			# safe source padding; extra virtual padding avoids the nearby row.
			result.region = Rect2(bounds.position - Vector2(3, 2), bounds.size + Vector2(6, 8))
			result.margin = Rect2(3, 4, 6, 4)
		result.filter_clip = true
		_textures[key] = result
	return _textures[key]


static func style_button(button: TextureButton, index: int) -> void:
	button.texture_normal = texture(index, 0)
	button.texture_hover = texture(index, 1)
	button.texture_pressed = texture(index, 2)
	button.texture_disabled = texture(index, 3)
	button.texture_focused = texture(index, 4)
