extends RefCounted

const SOURCE := "res://assets/city/han/ui/user-atlas/building-source.png"
# Normal, orange highlight, gray disabled; names are part of the source art.
const CELLS := {
	0: [Vector2(8, 12), Vector2(130, 12), Vector2(252, 12)],
	1: [Vector2(740, 12), Vector2(862, 12), Vector2(984, 12)],
	2: [Vector2(374, 12), Vector2(496, 12), Vector2(618, 12)],
	3: [Vector2(1106, 12), Vector2(1228, 12), Vector2(1350, 12)],
	4: [Vector2(1472, 12), Vector2(1594, 12), Vector2(1716, 12)],
	5: [Vector2(252, 140), Vector2(374, 140), Vector2(496, 140)],
	12: [Vector2(1838, 12), Vector2(8, 140), Vector2(130, 140)],
	13: [Vector2(618, 140), Vector2(740, 140), Vector2(862, 140)],
	14: [Vector2(984, 140), Vector2(1106, 140), Vector2(1228, 140)],
}
static var _textures: Dictionary = {}


static func texture(index: int, state: int = 0, show_name: bool = true) -> Texture2D:
	var key := "%d:%d:%s" % [index, state, show_name]
	if not _textures.has(key):
		var result: Texture2D = load("res://assets/city/han/ui/user-atlas/building-circle-%d-%d-%d.png" % [index, state, int(show_name)])
		_textures[key] = result
	return _textures[key]


static func style_button(button: TextureButton, index: int, show_name: bool = true, selected: bool = false) -> void:
	button.texture_normal = texture(index, 1 if selected else 0, show_name)
	button.texture_hover = texture(index, 1, show_name)
	button.texture_pressed = texture(index, 1, show_name)
	button.texture_disabled = texture(index, 2, show_name)
	button.texture_focused = texture(index, 1, show_name)
