extends Control

var record: Dictionary = {}
var names: Array[String] = []
var faces: Array = []
var muted_faces: Array = []
var elapsed := 0.0
var result_at := 8.0
var font := preload("res://scripts/ui/city_ui_skin.gd").font()
var versus := preload("res://assets/duel/ui/versus.png")
var victory := preload("res://assets/duel/ui/victory.png")
var defeat := preload("res://assets/duel/ui/defeat.png")
var paper_banner := preload("res://assets/duel/ui/paper-banner.png")
var name_ribbons := [preload("res://assets/duel/ui/name-blue.png"), preload("res://assets/duel/ui/name-rust.png")]
var quote_brush := preload("res://assets/duel/ui/quote-brush.png")
const Lines = preload("res://scripts/war/duel/duel_lines.gd")
var cuts: Array[Sprite2D] = []
var kill_slash: Texture2D = preload("res://assets/armies/rtk14/effects/duel-kill-slash.png")
var strike_trail: Texture2D = preload("res://assets/armies/rtk14/effects/arrow-trail.png")
var timeline: Array = []
var timing: Dictionary = {}
var refused := false
var courage: Array[int] = [0, 0]

func _ready() -> void:
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; render_mode blend_add; void fragment(){ vec4 t=texture(TEXTURE,UV); float light=pow(clamp((t.r-0.35)/0.65,0.0,1.0),2.0); COLOR=vec4(vec3(light),light*t.a*COLOR.a); }"
	for index in range(2):
		var cut := Sprite2D.new()
		cut.texture = strike_trail
		var material := ShaderMaterial.new()
		material.shader = shader
		cut.material = material
		cut.rotation = PI / 4.0 if index == 0 else -PI / 4.0
		add_child(cut)
		cuts.append(cut)

func _resolve_courage(data: Dictionary) -> Array[int]:
	var result: Array[int] = [0, 0]
	var profiles: Array = data.get("profiles", [])
	for index in range(mini(2, profiles.size())):
		result[index] = roundi(float(profiles[index].get("courage", 0)))
	return result

func configure(value: Dictionary) -> void:
	refused = false
	record = value
	timing = record.get("presentation", {"entry_seconds":1.2, "attack_seconds":0.55, "impact_seconds":0.15, "hp_blend_seconds":0.10})
	timeline = []
	var profiles_courage := _resolve_courage(record)
	if profiles_courage[0] > 0 or profiles_courage[1] > 0:
		courage = profiles_courage
	var at := float(timing.get("entry_seconds", 1.2))
	var rounds: Array = record.get("rounds", [])
	for index in range(rounds.size()):
		var row: Dictionary = rounds[index]
		var events: Array = row.get("events", [])
		if not row.has("events"):
			# Historical records preserve their original simultaneous settlement.
			var previous: Array = record.get("initial_hp", [100.0,100.0]) if index == 0 else [rounds[index-1].get("hp_a",100),rounds[index-1].get("hp_b",100)]
			events = [{"attacker":0,"defender":1,"hit":true,"hp_after":[previous[0],row.get("hp_b",previous[1])],"applied_damage":row.get("damage_b",0)}, {"attacker":1,"defender":0,"hit":true,"hp_after":[row.get("hp_a",previous[0]),row.get("hp_b",previous[1])],"applied_damage":row.get("damage_a",0)}]
		for event in events:
			timeline.append({"at":at, "round":index+1, "event":event})
			at += float(timing.get("attack_seconds", 0.55))
	result_at = at

func playback() -> Dictionary:
	var completed := 0
	var event: Dictionary = {}
	var phase := -1.0
	var round_index := 1
	for row in timeline:
		if elapsed < float(row["at"]): break
		round_index = int(row["round"])
		if elapsed >= float(row["at"]) + float(timing.get("attack_seconds", 0.55)):
			completed += 1
		else:
			event = row["event"]
			phase = elapsed - float(row["at"])
			break
	return {"completed":completed, "event":event, "phase":phase, "round":round_index}

func health_at(index: int, play: Dictionary) -> float:
	var completed: int = play["completed"]
	var initial: Array = record.get("initial_hp", [100.0,100.0])
	var previous := float(initial[index]) if completed == 0 else float(timeline[completed-1]["event"]["hp_after"][index])
	var event: Dictionary = play["event"]
	if event.is_empty(): return previous
	var impact := float(timing.get("impact_seconds", 0.15))
	return lerpf(previous, float(event["hp_after"][index]), smoothstep(impact, impact + float(timing.get("hp_blend_seconds",0.10)), float(play["phase"])))

func _process(_delta: float) -> void:
	if refused:
		# Refusal cards never play the combat timeline; keep slash sprites hidden.
		for cut in cuts:
			cut.visible = false
		return
	var play := playback()
	var event: Dictionary = play["event"]
	for index in range(cuts.size()):
		var phase := float(play["phase"]) - float(timing.get("impact_seconds",0.15))
		var active: bool = not event.is_empty() and int(event["attacker"]) == index and event.get("hit", false) and not event.get("blocked",false)
		var final_kill: bool = record.get("fate", {}).get("status", "") == "dead" and int(record.get("winner", -1)) == index
		if elapsed >= result_at:
			phase = elapsed - result_at
			active = final_kill
		var strength := 1.0 - smoothstep(0.06, 0.22, phase) if phase >= 0 and active else 0.0
		cuts[index].visible = strength > 0
		var killing: bool = elapsed >= result_at and final_kill
		cuts[index].texture = kill_slash if killing else strike_trail
		cuts[index].position = Vector2(180 + (1 - index) * 270, 215)
		# Keep the supplied 128x1024 slash at its original aspect ratio.
		cuts[index].scale = Vector2.ONE * 0.34 if killing else Vector2(0.3, 1.4)
		cuts[index].modulate.a = strength

func caption(text: String, rect: Rect2, font_size: int, color: Color) -> void:
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, rect.position + Vector2((rect.size.x - width) * 0.5, font_size), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	if refused:
		draw_refusal()
		return
	if names.size() < 2: return
	var ink := Color("393b36")
	draw_texture_rect(paper_banner, Rect2(40, 0, 540, 54), false)
	caption("单挑", Rect2(40, 0, 540, 54), 32, ink)
	var winner := int(record.get("winner", -1))
	var settled := elapsed >= result_at
	var play := playback()
	for i in range(2):
		if faces[i] != null:
			var lost := elapsed >= result_at + 0.25 and winner >= 0 and winner != i
			var texture: Texture2D = muted_faces[i] if lost and muted_faces.size() == 2 else faces[i]
			var entry := (1.0 - smoothstep(0.0, 0.6, elapsed)) * 55.0 * (-1 if i == 0 else 1)
			var face_size := texture.get_size()
			face_size *= minf(230.0 / face_size.x, 220.0 / face_size.y)
			var result_blend := smoothstep(result_at, result_at + 0.4, elapsed) if winner >= 0 else 0.0
			face_size *= lerpf(1.0, 1.10 if winner == i else 0.86, result_blend)
			var face_position := Vector2(180 + i * 270 + entry - face_size.x * 0.5, 336 - face_size.y)
			var current: Dictionary = play["event"]
			if not current.is_empty() and not settled:
				var phase := float(play["phase"])
				var impact := float(timing.get("impact_seconds",0.15))
				var actor: int = int(current["attacker"])
				var lunge := sin(clampf(phase / float(timing.get("attack_seconds",0.55)),0,1) * PI) * 14.0
				if actor == i:
					face_position.x += lunge * (1 if i == 0 else -1)
					face_position.y -= lunge * 0.15
				elif phase >= impact:
					var reaction := sin(clampf((phase-impact)/0.30,0,1)*PI)
					face_position.x += reaction * (8 if i == 1 else -8) if current.get("hit",false) else reaction * (22 if i == 1 else -22)
					if current.get("hit",false): face_position.x += sin(phase * 65) * reaction * 4
			draw_texture_rect(texture, Rect2(face_position, face_size), false)
	var current: Dictionary = play["event"]
	if not current.is_empty() and float(play["phase"]) >= float(timing.get("impact_seconds",0.15)):
		var defender := int(current["defender"])
		var label := "闪避" if not current.get("hit",false) else ("格挡 " if current.get("blocked",false) else "重击 " if current.get("critical",false) else "反击 " if current.get("type", "") == "counter" else "") + "−%d" % ceili(float(current.get("applied_damage",0)))
		caption(label, Rect2(55+defender*300,242,230,40), 26, Color("fff0b5"))
		if current.get("blocked",false):
			draw_circle(Vector2(310,220), 9.0, Color(1,1,.8,1.0-clampf((float(play["phase"])-.15)/.20,0,1)))
	var emblem: Texture2D = victory if settled and winner >= 0 else versus
	var emblem_size := emblem.get_size()
	emblem_size *= minf(148.0 / emblem_size.x, 72.0 / emblem_size.y)
	var emblem_center := Vector2(180 + winner * 270, 244) if settled and winner >= 0 else Vector2(310, 205)
	draw_texture_rect(emblem, Rect2(emblem_center - emblem_size * 0.5, emblem_size), false)
	if settled and winner >= 0:
		var fate_status := str(record.get("fate", {}).get("status", ""))
		var fate_mark: String = {"captured":"被俘", "dead":"战死"}.get(fate_status, "")
		if not fate_mark.is_empty():
			# Put the outcome over the defeated officer, paired with the victory emblem.
			var mark_size := 44
			var mark_width := font.get_string_size(fate_mark, HORIZONTAL_ALIGNMENT_LEFT, -1, mark_size).x
			var mark_position := Vector2(180 + (1 - winner) * 270 - mark_width * 0.5, 258)
			draw_string_outline(font, mark_position, fate_mark, HORIZONTAL_ALIGNMENT_LEFT, -1, mark_size, 8, Color("4b160e"))
			draw_string_outline(font, mark_position, fate_mark, HORIZONTAL_ALIGNMENT_LEFT, -1, mark_size, 5, Color("c63013"))
			draw_string(font, mark_position, fate_mark, HORIZONTAL_ALIGNMENT_LEFT, -1, mark_size, Color("ffe890"))
	draw_texture_rect(paper_banner, Rect2(10, 312, 600, 131), false)
	for i in range(2):
		var color := Color("467ebc") if i == 0 else Color("c34c47")
		var x := 32.0 + i * 306.0
		draw_texture_rect(name_ribbons[i], Rect2(x - 12, 294, 284, 34), false)
		caption(names[i], Rect2(x - 12, 293, 284, 34), 24, Color.WHITE)
		var hp := health_at(i, play)
		var maximum := float(record.get("max_hp", [100.0, 100.0])[i])
		var courage_val := courage[i] if courage.size() > i else 0
		if courage_val <= 0 and record.get("profiles", []).size() > i:
			courage_val = roundi(float(record["profiles"][i].get("courage", 0)))
		if courage_val > 0:
			caption("勇武  %d" % courage_val, Rect2(x, 329, 242, 24), 21, ink)
			caption("体力  %d / %d" % [ceili(hp), roundi(maximum)], Rect2(x, 355, 242, 24), 21, ink)
		else:
			caption("体力 %d / %d" % [ceili(hp), roundi(maximum)], Rect2(x, 336, 242, 38), 24, ink)
		draw_rect(Rect2(x, 382, 242, 8), Color("53574e"))
		draw_rect(Rect2(x + 1, 383, 240 * clampf(hp / maximum, 0, 1), 6), color)
		var text := "第 %d 回合" % int(play["round"]) if not settled else "平手" if winner < 0 else "胜方" if winner == i else "负方"
		caption(text, Rect2(x, 399, 242, 34), 22, ink)

func caption_wrapped(text: String, rect: Rect2, font_size: int, color: Color) -> void:
	var lines: Array[String] = []
	var line := ""
	for character in text:
		if font.get_string_size(line + character,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x > rect.size.x - 12:
			lines.append(line)
			line = ""
		line += character
	if not line.is_empty(): lines.append(line)
	for index in range(lines.size()):
		caption(lines[index], Rect2(rect.position + Vector2(0,index*20),Vector2(rect.size.x,20)),font_size,color)

func refusal_text() -> String:
	var message := str(record.get("message", "")).strip_edges()
	if not message.is_empty():
		return message
	return "%s 拒绝应战" % names[1] if names.size() >= 2 else "对手拒绝应战"

func draw_refusal() -> void:
	# Lightweight card: only the original brush banner and the refusal line.
	var source := quote_brush.get_size()
	var height := 560.0 * source.y / source.x
	var banner := Rect2(30, 225.0 - height * 0.5, 560, height)
	draw_texture_rect(quote_brush, banner, false)
	var font_size := 26
	var line_height := font_size + 8.0
	var max_width := banner.size.x - 160.0
	var lines: Array[String] = []
	var line := ""
	for character in refusal_text():
		if not line.is_empty() and font.get_string_size(line + character, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > max_width:
			lines.append(line)
			line = ""
		line += character
	if not line.is_empty(): lines.append(line)
	var block := line_height * (lines.size() - 1) + font_size
	var top := banner.position.y + (banner.size.y - block) * 0.5
	for index in range(lines.size()):
		var width := font.get_string_size(lines[index], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var position := Vector2(banner.get_center().x - width * 0.5, top + font_size + line_height * index)
		draw_string_outline(font, position, lines[index], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0.06, 0.05, 0.03, 0.75))
		draw_string(font, position, lines[index], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("ffe7ad"))
