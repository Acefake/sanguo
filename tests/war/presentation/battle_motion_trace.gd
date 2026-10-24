extends SceneTree
func _initialize(): call_deferred("run")
func run():
 var s=root.get_node("GameState")
 s.persist_enabled=false
 s.prepare_battle_test(true)
 var history=[]
 for day in range(25):
  await s.war.step(null)
  var units=[]
  for a in s.war.active_armies():
   units.append({"id":a.id,"name":a.name,"cell":a.tactical.cell,"role":a.corps_task.type,"phase":a.tactical.phase,"target":a.tactical.attack_target,"flank":a.tactical.get("flank_ready",false),"returning":a.returning})
  history.append({"tick":s.war.state.tick,"units":units})
 var f=FileAccess.open("res://docs/validation/battle-motion-after.json",FileAccess.WRITE)
 f.store_string(JSON.stringify(history,"\t"))
 print("MOTION_TRACE_OK")
 quit()
