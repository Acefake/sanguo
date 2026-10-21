extends RefCounted

# User-supplied sheet stays intact. Regions and background masks are cached once.
const SOURCE := "res://assets/city/han/ui/user-atlas/source.png"
const REGIONS := {
	"paper": Rect2i(457, 39, 35, 38),
	"header": Rect2i(129, 120, 159, 22),
	"dark_panel": Rect2i(902, 198, 94, 31),
	"button_normal": Rect2i(201, 455, 165, 49),
	"button_hover": Rect2i(375, 455, 165, 49),
	"button_pressed": Rect2i(200, 510, 166, 50),
	"button_disabled": Rect2i(375, 510, 165, 50),
	"button_red": Rect2i(1004, 195, 94, 30),
	"button_red_hover": Rect2i(1004, 230, 94, 30),
	"button_red_pressed": Rect2i(612, 237, 94, 31),
	"button_small_disabled": Rect2i(710, 237, 95, 31),
	"focus_gold": Rect2i(10, 385, 188, 66),
	"focus_silver": Rect2i(386, 385, 184, 66),
	"octagon_red": Rect2i(617, 41, 76, 77),
	"octagon_hover": Rect2i(710, 41, 76, 77),
	"octagon_pressed": Rect2i(984, 41, 76, 77),
	"octagon_disabled": Rect2i(893, 41, 76, 77),
	"octagon_outline": Rect2i(710, 41, 76, 77),
	"token_normal": Rect2i(689, 132, 56, 57),
	"token_hover": Rect2i(750, 132, 58, 57),
	"token_pressed": Rect2i(813, 132, 58, 57),
	"token_disabled": Rect2i(877, 132, 56, 57),
	"token_focus": Rect2i(1065, 132, 59, 57),
	"token_outline": Rect2i(1065, 132, 59, 57),
	"bar_track": Rect2i(231, 210, 97, 5),
	"bar_fill": Rect2i(300, 210, 71, 5),
}
static var _image: Image
static var _textures: Dictionary = {}


static func texture(key: String) -> Texture2D:
	if _textures.has(key):
		return _textures[key]
	if _image == null:
		_image = (load(SOURCE) as Texture2D).get_image()
		if _image.is_compressed():
			_image.decompress()
		_image.convert(Image.FORMAT_RGBA8)
	var region: Rect2i = REGIONS[key]
	var slice := _image.get_region(region)
	if key.begins_with("octagon_") or key.begins_with("token_"):
		_clip_shape(slice, 0.27 if key.begins_with("octagon_") else 0.22)
	elif key.begins_with("button_") or key == "dark_panel":
		_clip_shape(slice, 0.18)
	elif key not in ["paper", "header", "bar_track", "bar_fill"]:
		_remove_backdrop(slice, key.begins_with("focus_"))
	if key.ends_with("_outline"):
		_outline(slice)
	slice.generate_mipmaps()
	var result := ImageTexture.create_from_image(slice)
	_textures[key] = result
	return result


static func _is_backdrop(color: Color) -> bool:
	# Match the opaque #202020 matte, not the dark interiors of disabled buttons.
	return absf(color.r - 32.0 / 255.0) < 0.10 and absf(color.g - 32.0 / 255.0) < 0.10 and absf(color.b - 32.0 / 255.0) < 0.10


static func _clip_shape(slice: Image, corner_ratio: float) -> void:
	# Shape masks isolate the original art even where the flattened sheet has
	# compression noise. Filled dark button interiors are never color-keyed.
	var width := float(slice.get_width())
	var height := float(slice.get_height())
	var cut := height * corner_ratio
	var edge := 1.5
	var shape := PackedVector2Array([
		Vector2(edge + cut, edge), Vector2(width - edge - cut, edge),
		Vector2(width - edge, edge + cut), Vector2(width - edge, height - edge - cut),
		Vector2(width - edge - cut, height - edge), Vector2(edge + cut, height - edge),
		Vector2(edge, height - edge - cut), Vector2(edge, edge + cut),
	])
	for y in range(slice.get_height()):
		for x in range(slice.get_width()):
			var coverage := 0.0
			for offset in [Vector2(0.25, 0.25), Vector2(0.75, 0.25), Vector2(0.25, 0.75), Vector2(0.75, 0.75)]:
				if Geometry2D.is_point_in_polygon(Vector2(x, y) + offset, shape):
					coverage += 0.25
			var color := slice.get_pixel(x, y)
			color.a *= coverage
			slice.set_pixel(x, y, color)


static func _remove_backdrop(slice: Image, hollow: bool) -> void:
	var width := slice.get_width()
	var height := slice.get_height()
	var visited := PackedByteArray()
	visited.resize(width * height)
	var queue := PackedInt32Array()
	for y in range(height):
		for x in range(width):
			if (hollow or x == 0 or y == 0 or x == width - 1 or y == height - 1) and _is_backdrop(slice.get_pixel(x, y)):
				var index := y * width + x
				visited[index] = 1
				queue.append(index)
	var cursor := 0
	while cursor < queue.size():
		var index := queue[cursor]
		cursor += 1
		var x := index % width
		var y := int(index / width)
		slice.set_pixel(x, y, Color.TRANSPARENT)
		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var next: Vector2i = Vector2i(x, y) + offset
			if next.x < 0 or next.y < 0 or next.x >= width or next.y >= height:
				continue
			var next_index: int = next.y * width + next.x
			if visited[next_index] == 0 and _is_backdrop(slice.get_pixelv(next)):
				visited[next_index] = 1
				queue.append(next_index)


static func _outline(slice: Image) -> void:
	var original := slice.duplicate() as Image
	for y in range(3, slice.get_height() - 3):
		for x in range(3, slice.get_width() - 3):
			var inside := true
			for offset in [Vector2i(-3, 0), Vector2i(3, 0), Vector2i(0, -3), Vector2i(0, 3)]:
				if original.get_pixelv(Vector2i(x, y) + offset).a < 0.5:
					inside = false
					break
			if inside:
				slice.set_pixel(x, y, Color.TRANSPARENT)
