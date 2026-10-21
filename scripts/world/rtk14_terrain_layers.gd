extends RefCounted

const ASSET_DIR := "res://assets/rtk14/terrain/"
const LAYER_BYTES := 1398128
const LAYER_COUNT := 19

static func load_layers(role: String) -> Texture2DArray:
	var file := FileAccess.open(ASSET_DIR + "layers_" + role + ".bc3", FileAccess.READ)
	assert(file != null, "Native terrain array missing: " + role)
	assert(file.get_length() == LAYER_BYTES * LAYER_COUNT)
	var slices: Array[Image] = []
	for layer in range(LAYER_COUNT):
		slices.append(Image.create_from_data(1024, 1024, true, Image.FORMAT_DXT5,
			file.get_buffer(LAYER_BYTES)))
	var texture := Texture2DArray.new()
	assert(texture.create_from_images(slices) == OK)
	return texture
