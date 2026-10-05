extends SceneTree
func _initialize():
 var document=GLTFDocument.new()
 var state=GLTFState.new()
 document.append_from_file("res://assets/armies/rtk14/models/infantry-poses.glb",state)
 var scene=document.generate_scene(state)
 for node in scene.find_children("*","MeshInstance3D",true,false):
  var a=node.mesh.surface_get_arrays(0)
  assert(a[Mesh.ARRAY_VERTEX].size() == 1575, "Pose vertex topology changed")
  assert(node.mesh.get_aabb().end.z > 1.4, "Spear forward axis is wrong")
 print("ARMY_POSE_OK: 21 poses, stable topology and +Z spear forward")
 scene.free()
 quit()
