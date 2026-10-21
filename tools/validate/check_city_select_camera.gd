extends SceneTree
func _initialize() -> void:
    var world = load("res://scripts/world/rtk14_world_3d.gd").new()
    var city := Node3D.new()
    world.add_child(city)
    world.city_nodes["luoyang"] = city
    world.city_foundations["luoyang"] = {"height": 0.0, "selection_radius": 15.0}
    world.selected_ring = MeshInstance3D.new()
    world.selected_ring.mesh = TorusMesh.new()
    world.add_child(world.selected_ring)
    world.city_popup = PanelContainer.new()
    world.add_child(world.city_popup)
    var target = world.target_goal
    var zoom = world.distance_goal
    var yaw = world.yaw
    var pitch = world.pitch
    world._select_city("luoyang")
    assert(world.target_goal == target and world.distance_goal == zoom and world.yaw == yaw and world.pitch == pitch)
    assert(world.selected_city == "luoyang" and world.city_popup.visible)
    world.free()
    print("CITY_SELECT_CAMERA_UNCHANGED")
    quit()
