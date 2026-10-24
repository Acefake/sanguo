extends SceneTree
func _initialize(): call_deferred("run")
func run():
 var s=root.get_node("GameState")
 s.persist_enabled=false
 s.prepare_battle_test()
 var results=[]
 for day in range(120):
  await s.war.step(null)
  results.append({"tick":s.war.state.tick,"armies":s.war.active_armies().size(),"units":s.war.active_armies().map(func(a): return {"id":a.id,"name":a.name,"faction":a.faction,"strength":s.war.Combat.strength(a),"morale":a.morale,"organization":a.organization,"task":a.corps_task.type,"returning":a.returning,"reason":a.get("retreat_reason",a.outcome),"morale_change":a.get("morale_change",0),"morale_reason":a.get("morale_reason","")}),"siege":s.war.state.sieges.get("xiaopei",{}).duplicate(true),"winner":s.war.state.battlefield.get("winner", ""),"owner":s.city_state("xiaopei").faction})
  if s.war.state.battlefield.has("winner"):break
 var f=FileAccess.open("res://docs/validation/xiaopei-campaign-run.json",FileAccess.WRITE)
 f.store_string(JSON.stringify(results,"\t"))
 print("XIAOPEI_CAMPAIGN_RUN ",JSON.stringify(results[-1]))
 quit()
