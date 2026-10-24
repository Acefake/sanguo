extends SceneTree

const Grid = preload("res://scripts/rtk14_hex_grid.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var grid = Grid.new()
	assert(grid.load_source())
	assert(grid.words.size() == 48400 * 4)
	assert(grid.pick(Vector2(-100,-100)) == -1)
	assert(grid.neighbors(0).size() == 2)
	assert(grid.neighbors(221).size() == 6)
	var start := -1
	var goal := -1
	for cell in range(48400):
		assert(grid.words[cell * 4] == cell, "Original cell identity")
		if cell % 23 == 0:
			assert(grid.pick(grid.center(cell)) == cell, "Center picking")
			for neighbor in grid.neighbors(cell):
				assert(grid.neighbors(neighbor).has(cell), "Reciprocal adjacency")
				var shared := 0
				for a in grid.polygon(cell):
					for b in grid.polygon(neighbor):
						if a.is_equal_approx(b): shared += 1
				assert(shared == 2, "Hexagons must share exactly one edge")
		if start == -1 and grid.walkable(cell):
			for neighbor in grid.neighbors(cell):
				if grid.walkable(neighbor):
					start = cell
					goal = neighbor
	assert(start >= 0)
	var path: PackedInt32Array = grid.find_path(start, goal)
	assert(path.size() == 2 and path[0] == start and path[-1] == goal)
	assert(grid.find_path(-1, goal).is_empty())
	assert(grid.find_path(start, start).size() == 1)
	var frontier: Array[int] = [start]
	var visited := {start: true}
	var cursor := 0
	while cursor < frontier.size() and cursor < 400:
		for neighbor in grid.neighbors(frontier[cursor]):
			if grid.walkable(neighbor) and not visited.has(neighbor):
				visited[neighbor] = true
				frontier.append(neighbor)
		cursor += 1
	var long_path: PackedInt32Array = grid.find_path(start, frontier[-1])
	assert(long_path.size() > 10, "Multi-cell path")
	for index in range(long_path.size()):
		assert(grid.walkable(long_path[index]), "Path cannot cross blocked terrain")
		if index > 0:
			assert(grid.neighbors(long_path[index - 1]).has(long_path[index]), "Path must follow hex edges")
	change_scene_to_file("res://scenes/map_slice.tscn")
	await process_frame
	await process_frame
	var map = current_scene
	var registration: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/world_2d_registration.json"))
	assert(registration["matched_cities"] == 46 and registration["max_centroid_residual_px"] < 5)
	var pixel_parameters: Array = registration["texture_parameters"]
	var texture_cell := Vector2(pixel_parameters[2] + (start % 220) * pixel_parameters[0], pixel_parameters[3] + (start / 220 + (start % 2) * 0.5) * pixel_parameters[1])
	assert((texture_cell * map.texture_scale + map.texture_offset).is_equal_approx(grid.center(start)), "Texture and interaction grid must use the same coordinates")
	map.camera.zoom = Vector2.ONE * 6
	map.camera.position = grid.center(start)
	map._clamp_camera()
	map._select_at(grid.center(start))
	assert(map.selected_cell == start)
	map._preview_cell_path(goal)
	assert(map.cell_path.size() == 2)
	assert(map.cell_label.text.contains("路径预览"))
	map._unhandled_input(InputEventKey.new())
	map._reset_view()
	print("RTK14_HEX_OK count=48400 picking=ok neighbors=ok shared_edges=ok path=ok integration=ok")
	if DisplayServer.get_name() != "headless":
		map.camera.zoom = Vector2.ONE * 5
		map.camera.position = map._place_position("luoyang")
		map._clamp_camera()
		map.hex_overlay.show_ownership = true
		map.hex_overlay.queue_redraw()
		map.selected_cell = grid.pick(map._place_position("luoyang"))
		map.hovered_cell = grid.neighbors(map.selected_cell)[0]
		map.cell_path.clear()
		map.path_message = ""
		map._refresh_cell_panel()
		map.queue_redraw()
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tests/rtk14-hex-closeup.png")
	quit()
