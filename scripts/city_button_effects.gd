extends RefCounted

const BINDING_KEY := &"city_icon_feedback"


static func bind_icon(button: TextureButton) -> void:
	if button == null or button.has_meta(BINDING_KEY):
		return
	button.set_meta(BINDING_KEY, true)
	var feedback := IconFeedback.new()
	feedback.button = button
	button.add_child(feedback)
	feedback.bind()


class IconFeedback extends Control:
	const NORMAL := Color(0.90, 0.87, 0.80, 1.0)
	const HOVER := Color(1.06, 1.00, 0.88, 1.0)
	const FOCUS := Color(1.03, 0.98, 0.87, 1.0)
	const PRESSED := Color(0.85, 0.78, 0.64, 1.0)
	const DISABLED := Color(0.60, 0.60, 0.55, 0.68)
	const FOCUS_RING := Color(0.96, 0.79, 0.48, 0.95)
	const DURATION := 0.10

	var button: TextureButton
	var hovered := false
	var pressing := false
	var focused := false
	var was_disabled := false
	var base_color := Color.WHITE
	var base_scale := Vector2.ONE
	var tween: Tween
	var focus_alpha := 0.0:
		set(value):
			focus_alpha = value
			queue_redraw()

	func bind() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		base_color = button.self_modulate
		base_scale = button.scale
		focused = button.has_focus()
		was_disabled = button.disabled
		button.resized.connect(_update_pivot)
		button.mouse_entered.connect(_on_mouse_entered)
		button.mouse_exited.connect(_on_mouse_exited)
		button.focus_entered.connect(_on_focus_entered)
		button.focus_exited.connect(_on_focus_exited)
		button.button_down.connect(_on_button_down)
		button.button_up.connect(_on_button_up)
		button.visibility_changed.connect(_on_visibility_changed)
		_update_pivot()
		_refresh(false)


	func _process(_delta: float) -> void:
		# BaseButton has no disabled_changed signal; watch this one property.
		if button.disabled != was_disabled:
			was_disabled = button.disabled
			pressing = false
			_refresh()


	func _draw() -> void:
		if focus_alpha <= 0.001 or button.texture_focused != null:
			return
		var radius := maxf(minf(size.x, size.y) * 0.5 - 1.0, 1.0)
		var color := FOCUS_RING
		color.a *= focus_alpha
		draw_arc(size * 0.5, radius, 0.0, TAU, 64, color, 1.5, true)


	func _update_pivot() -> void:
		button.pivot_offset = button.size * 0.5
		queue_redraw()


	func _on_mouse_entered() -> void:
		hovered = true
		_refresh()


	func _on_mouse_exited() -> void:
		hovered = false
		pressing = false
		_refresh()


	func _on_focus_entered() -> void:
		focused = true
		_refresh()


	func _on_focus_exited() -> void:
		focused = false
		pressing = false
		_refresh()


	func _on_button_down() -> void:
		pressing = true
		_refresh()


	func _on_button_up() -> void:
		pressing = false
		_refresh()


	func _on_visibility_changed() -> void:
		if not button.is_visible_in_tree():
			hovered = false
			pressing = false
			focused = false
			_refresh(false)
		else:
			focused = button.has_focus()
			_refresh(false)


	func _refresh(animate: bool = true) -> void:
		var tint := NORMAL
		var scale_factor := 1.0
		if button.disabled:
			tint = DISABLED
		elif pressing:
			tint = PRESSED
			scale_factor = 0.955
		elif hovered:
			tint = HOVER
			scale_factor = 1.025
		elif focused:
			tint = FOCUS
		var target_color := base_color * tint
		# The atlas provides real normal/hover/pressed/disabled artwork.
		if button.texture_hover != null:
			target_color = base_color
		var target_scale := base_scale * (1.0 if button.get_meta("fixed_icon_size", false) else scale_factor)
		var target_focus := 1.0 if focused and not button.disabled else 0.0
		if tween != null and tween.is_valid():
			tween.kill()
		if not animate or not button.is_visible_in_tree():
			button.self_modulate = target_color
			button.scale = target_scale
			focus_alpha = target_focus
			return
		tween = button.create_tween()
		tween.set_parallel(true)
		tween.set_trans(Tween.TRANS_QUAD)
		tween.set_ease(Tween.EASE_OUT)
		tween.tween_property(button, "self_modulate", target_color, DURATION)
		tween.tween_property(button, "scale", target_scale, DURATION)
		tween.tween_property(self, "focus_alpha", target_focus, DURATION)
