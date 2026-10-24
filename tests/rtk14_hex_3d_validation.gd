extends SceneTree

class MapFixture extends Node3D:
	const HEIGHT_SCALE := 0.01
	const WATER_LEVEL := 0.3
	var terrain_root := Node3D.new()
	var camera := Camera3D.new()
	var heights := PackedFloat32Array([10000.0])
	var city_interior: CanvasLayer
	var officer_page: CanvasLayer
	var dragging_button := 0
	var city_data: Array = []
	func height_at(x: float, z: float) -> float:
		return 8.0 + sin(x * 0.02) * 4.0 + cos(z * 0.016) * 2.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := MapFixture.new()
	root.add_child(fixture)
	fixture.add_child(fixture.terrain_root)
	fixture.add_child(fixture.camera)
	fixture.camera.current = true
	fixture.camera.far = 6000
	var chunk := MeshInstance3D.new()
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/rtk14_terrain.gdshader")
	chunk.material_override = material
	fixture.terrain_root.add_child(chunk)
	var overlay = load("res://scripts/rtk14_hex_world_3d.gd").new()
	overlay.map = fixture
	fixture.add_child(overlay)
	assert(overlay.materials.size() == 1)
	assert(material.get_shader_parameter("hex_grid_enabled"))
	var target_cell := 15000
	var center: Vector2 = overlay.grid.center(target_cell)
	var target := Vector3(center.x, fixture.height_at(center.x, center.y), center.y)
	for view in [Vector3(0,100,90), Vector3(100,65,30), Vector3(-75,80,-65), Vector3(0,1100,1100)]:
		fixture.camera.position = target + view
		fixture.camera.look_at(target)
		var screen := fixture.camera.unproject_position(target)
		var hit: Variant = overlay.ground_at_screen(screen)
		assert(hit is Vector3 and hit.distance_to(target) < 0.03, "Ray must hit the heightfield under tilted/rotated cameras")
		assert(overlay.cell_at_screen(screen) == target_cell)
		overlay.select_screen(screen)
		assert(overlay.selected_cell == target_cell)
		assert(material.get_shader_parameter("hex_selected") == Vector2(target_cell % 220, target_cell / 220))
	var start := -1
	var goal := -1
	for cell in range(48400):
		if start >= 0: break
		if overlay.grid.walkable(cell):
			for neighbor in overlay.grid.neighbors(cell):
				if overlay.grid.walkable(neighbor):
					start = cell
					goal = neighbor
	overlay.path = overlay.grid.find_path(start,goal)
	overlay._build_path_mesh()
	assert(overlay.path_mesh.mesh.get_surface_count() == 1)
	var vertices: PackedVector3Array = overlay.path_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for point in vertices:
		assert(absf(point.y - fixture.height_at(point.x,point.z) - 0.16) < 0.001, "Route must follow heightfield")
	overlay.toggle()
	assert(not material.get_shader_parameter("hex_grid_enabled"))
	overlay.clear_selection()
	assert(overlay.selected_cell == -1 and overlay.path_mesh.mesh == null)
	fixture.queue_free()
	await process_frame
	print("RTK14_HEX_3D_OK heightfield_pick=ok rotated_cameras=4 selection=ok surface_route=ok toggle=ok")
	quit()
