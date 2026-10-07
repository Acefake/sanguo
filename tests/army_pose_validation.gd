extends SceneTree
func _initialize():
 var document=GLTFDocument.new()
 var state=GLTFState.new()
 assert(document.append_from_file("res://assets/armies/rtk14/models/infantry-poses.glb",state) == OK)
 var scene=document.generate_scene(state)
 var nodes=scene.find_children("*","MeshInstance3D",true,false)
 assert(nodes.size() == 29, "Native pose count changed")
 var idle: PackedVector3Array = nodes[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
 for node in nodes:
  var points: PackedVector3Array = node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
  assert(points.size() == idle.size() and points.size() == 1575, "Native topology changed")
  for point in points: assert(point.is_finite() and point.y > -0.2 and point.y < 3.5, "Broken native skin binding")
 var strike: PackedVector3Array = nodes[14].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
 var march: PackedVector3Array = nodes[4].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
 var attack_motion := 0.0
 var march_motion := 0.0
 for i in range(idle.size()):
  attack_motion=maxf(attack_motion,idle[i].distance_to(strike[i]))
  march_motion=maxf(march_motion,idle[i].distance_to(march[i]))
 assert(attack_motion > 0.2 and march_motion > 0.1,"Decoded native poses do not move")
 var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/armies/rtk14/field_animation_sources.json"))
 assert(source["infantry"]["clips"].size() == 3,"Native clip provenance missing")
 print("ARMY_POSE_OK: 29 native G2A poses, stable skin topology, attack %.3f march %.3f" % [attack_motion,march_motion])
 scene.free()
 quit()
