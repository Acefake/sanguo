extends RefCounted

const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")

# A two-round estimate on a private knowledge copy. No war object, RNG, execution
# or loss application is available here. Enemy reactions are estimates, not facts.
static func project(context: Dictionary, candidate: Dictionary) -> Dictionary:
	var board: Dictionary = context["knowledge"]["terrain"]
	var own: Dictionary = context["self"]
	var cell := int(own["cell"])
	var original := cell
	var strength := float(own["strength"])
	# Distant enemies remain in the risk view. They cannot reach the predicted
	# position within this two-round movement horizon and need no simulated turn.
	var enemies: Array = context["knowledge"]["enemies"].filter(func(e): return int(e.get("cell",-1)) >= 0 and Tactical.cell_distance(cell,int(e["cell"])) <= 6).duplicate(true)
	var allies: Array = context["knowledge"]["allies"]
	var total_loss := 0.0
	var total_kill := 0.0
	var rounds: Array = []
	var rally: bool = candidate["canonical_plan"]["template"] == "rally"
	var uncertainty := 0.0
	var goal := int(candidate["action"]["goal_cell"])
	var stop := int(candidate["action"].get("stop_distance",0))
	for round_index in range(2):
		var occupied := {}
		for ally in allies:
			if int(ally.get("cell",-1)) >= 0: occupied[int(ally["cell"])] = true
		for enemy in enemies:
			if int(enemy.get("cell",-1)) >= 0: occupied[int(enemy["cell"])] = true
		if round_index == 0:
			cell = int(candidate["next_cell"])
			if candidate["action"]["type"] == "local_disengage" and int(own["withdraw_preparation"])+1 < int(own["contact"]["required_preparation"]): cell = original
		elif candidate["stage"] not in ["recover","wait_support"] and Tactical.cell_distance(cell,goal) > stop:
			cell = approach(board,cell,goal,occupied)
		var loss := 0.0
		var kill := 0.0
		var attackers := 0
		for enemy in enemies:
			var enemy_cell := int(enemy.get("cell",-1))
			if enemy_cell < 0 or float(enemy.get("strength_estimate",0)) <= 0: continue
			var exchange: Dictionary = context["exchanges"].get(enemy["id"],{})
			var enemy_range := int(exchange.get("range",1))
			var gap := Tactical.cell_distance(cell,enemy_cell)
			if gap > enemy_range and not enemy.get("routing",false):
				occupied.erase(enemy_cell)
				var closer := approach(board,enemy_cell,cell,occupied)
				occupied[closer] = true
				enemy["cell"] = closer
				gap = Tactical.cell_distance(cell,closer)
				uncertainty += 0.1
			if gap <= enemy_range and gap > 0 and (gap == 1 or Tactical.Fort.line_of_sight(board,cell,int(enemy["cell"]))):
				var engagement := 1
				for ally in allies:
					if ally.get("can_support",false) and int(ally.get("cell",-1)) >= 0 and Tactical.cell_distance(int(ally["cell"]),int(enemy["cell"])) <= enemy_range: engagement += 1
				loss += float(exchange.get("own_loss_ranged",0) if gap > 1 else exchange.get("own_loss",0)) / engagement
				attackers += 1
			if not rally and candidate["canonical_plan"]["target_id"] == enemy["id"] and gap > 0 and gap <= int(own["attack_range"]):
				kill += float(exchange.get("enemy_loss_ranged",0) if gap > 1 else exchange.get("enemy_loss",0))
			uncertainty += (1-float(enemy.get("confidence",1)))*0.1
		loss = minf(strength,loss)
		strength -= loss
		total_loss += loss
		total_kill += kill
		rounds.append({"round":round_index+1,"cell":cell,"own_loss":int(loss),"enemy_loss":int(kill),"attackers":attackers,"remaining_strength":int(strength)})
	var progress := Tactical.cell_distance(original,goal)-Tactical.cell_distance(cell,goal)
	var future := progress*1.5 + minf(3,total_kill/maxf(1,float(own["strength"]))*60) - total_loss/maxf(1,float(own["strength"]))*60
	if rally and cell == goal: future += 3
	return {"horizon":2,"rounds":rounds,"projected_own_loss":int(total_loss),"projected_enemy_loss":int(total_kill),"loss_interval":[int(total_loss*0.6),int(total_loss*(1.4+minf(0.6,uncertainty)))],"reaction_uncertainty":uncertainty,"future_gain":clampf(future,-5,5)}

static func approach(board: Dictionary, cell: int, goal: int, occupied: Dictionary) -> int:
	var next := cell
	var gap := Tactical.cell_distance(cell,goal)
	for option in Tactical.neighbors(cell):
		if occupied.has(option) or not Tactical.in_battlefield(board,option) or board["blocked"].has(option) or not Tactical.grid().walkable(option): continue
		var remaining := Tactical.cell_distance(option,goal)
		if remaining < gap: next = option; gap = remaining
	return next
