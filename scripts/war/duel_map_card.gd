extends Control

var record: Dictionary = {}
var names: Array[String] = []
var faces: Array = []
var muted_faces: Array = []
var elapsed := 0.0
var result_at := 8.0
var font := preload("res://scripts/city_ui_skin.gd").font()
var versus := preload("res://assets/duel/ui/versus.png")
var victory := preload("res://assets/duel/ui/victory.png")
var defeat := preload("res://assets/duel/ui/defeat.png")

func caption(text: String, rect: Rect2, font_size: int, color: Color) -> void:
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, rect.position + Vector2((rect.size.x - width) * 0.5, font_size), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	if names.size() < 2: return
	var ink := Color("393b36")
	var paper := Color(0.94, 0.93, 0.85, 0.92)
	draw_style_box(_paper(), Rect2(10, 0, 600, 54))
	caption("单挑", Rect2(10, 0, 600, 54), 36, ink)
	var winner := int(record.get("winner", -1))
	var settled := elapsed >= result_at
	for i in range(2):
		if faces[i] != null:
			var lost := elapsed >= result_at + 0.25 and winner >= 0 and winner != i
			var texture: Texture2D = muted_faces[i] if lost and muted_faces.size() == 2 else faces[i]
			var entry := (1.0 - smoothstep(0.0, 0.6, elapsed)) * 55.0 * (-1 if i == 0 else 1)
			var face_size := texture.get_size()
			face_size *= minf(230.0 / face_size.x, 270.0 / face_size.y)
			var face_position := Vector2(65 + i * 270 + entry + (230 - face_size.x) * 0.5, 328 - face_size.y)
			draw_texture_rect(texture, Rect2(face_position, face_size), false)
	var emblem: Texture2D = victory if settled and winner >= 0 else versus
	var emblem_size := emblem.get_size()
	emblem_size *= minf(175.0 / emblem_size.x, 100.0 / emblem_size.y)
	draw_texture_rect(emblem, Rect2(Vector2(310, 195) - emblem_size * 0.5, emblem_size), false)
	# A decisive final strike lands on the defeated portrait, before the result rests.
	var strike_age := elapsed - result_at
	if winner >= 0 and strike_age >= 0.0 and strike_age < 0.9:
		var center := Vector2(180 + (1 - winner) * 270, 185)
		var travel := clampf(strike_age / 0.2, 0.0, 1.0)
		var fade := 1.0 - smoothstep(0.25, 0.9, strike_age)
		var start := center + Vector2(-100, -105)
		var finish := start.lerp(center + Vector2(100, 105), travel)
		draw_line(start, finish, Color(1, 0.58, 0.1, fade * 0.4), 24, true)
		draw_line(start, finish, Color(1, 0.86, 0.3, fade), 9, true)
		draw_line(start, finish, Color(1, 1, 0.88, fade), 3, true)
		for ray in range(8):
			var direction := Vector2.from_angle(ray * TAU / 8.0)
			draw_line(center + direction * 12, center + direction * (25 + strike_age * 85), Color(1, 0.85, 0.3, fade), 2, true)
	draw_style_box(_paper(), Rect2(10, 328, 600, 115))
	var rounds: Array = record.get("rounds", [])
	var progress := clampf(elapsed / result_at, 0, 1) * rounds.size()
	var completed := mini(int(progress), rounds.size())
	for i in range(2):
		var color := Color("467ebc") if i == 0 else Color("c34c47")
		var x := 32.0 + i * 306.0
		draw_rect(Rect2(x - 12, 294, 284, 34), Color(color, 0.85))
		caption(names[i], Rect2(x - 12, 294, 284, 34), 26, Color.WHITE)
		var field := "hp_a" if i == 0 else "hp_b"
		var previous := 100.0 if completed == 0 else float(rounds[completed - 1].get(field, 100))
		var next := float(rounds[completed].get(field, previous)) if completed < rounds.size() else previous
		var hp := lerpf(previous, next, progress - completed)
		caption("体力 %d / 100" % ceili(hp), Rect2(x, 336, 242, 38), 27, ink)
		draw_rect(Rect2(x, 379, 242, 12), Color("53574e"))
		draw_rect(Rect2(x + 2, 381, 238 * hp / 100.0, 8), color)
		var text := "交锋中" if not settled else "平手" if winner < 0 else "胜方" if winner == i else "负方"
		if settled and winner >= 0 and winner != i:
			var fate: Dictionary = record.get("fate", {})
			text += {"dead": " · 被斩杀", "captured": " · 被俘"}.get(fate.get("status", ""), "")
		caption(text, Rect2(x, 401, 242, 34), 25, ink)

func _paper() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.94, 0.93, 0.85, 0.9)
	style.corner_radius_top_left = 25
	style.corner_radius_top_right = 25
	style.corner_radius_bottom_left = 25
	style.corner_radius_bottom_right = 25
	return style
