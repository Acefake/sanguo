extends RefCounted

# Single source of truth for the design canvas.
#
# Every hand-authored layout is written in these logical pixels. With
# `display/window/stretch/mode="canvas_items"` plus `aspect="expand"`, Godot
# guarantees at least DESIGN is visible and hands the wider axis extra pixels,
# so responsive code should anchor to an edge rather than reposition itself.
#
# Previously 1260x710 was inlined in project.godot, officer_page.gd,
# duel_presentation.gd and city_interior.gd, while world_map_hud.gd used
# 1280x720. The mismatch made the 3D HUD render at 98.4% of every other
# screen. Nothing should hardcode these numbers again.

const DESIGN := Vector2(1260, 710)


# Scales and centers `frame` on whatever the viewport actually provides.
# Idempotent, so it is safe to call on every resize.
static func fit_center(frame: Control) -> void:
	var available := frame.get_viewport().get_visible_rect().size
	if available.x <= 0.0 or available.y <= 0.0:
		return
	var factor := minf(available.x / DESIGN.x, available.y / DESIGN.y)
	frame.scale = Vector2.ONE * factor
	frame.position = (available - DESIGN * factor) * 0.5


# Wires `frame` to stay fitted and centered across window resizes.
static func bind_fit(frame: Control) -> void:
	fit_center(frame)
	var viewport := frame.get_viewport()
	if not viewport.size_changed.is_connected(fit_center):
		viewport.size_changed.connect(fit_center.bind(frame))


# Right-edge offset helper: converts a design-space width into the negative
# offset an element needs to sit flush against the right anchor.
static func right_offset(design_right: float, margin: float) -> float:
	return -margin - design_right


# Bottom-edge offset helper, same idea for vertically stacked HUD furniture.
static func bottom_offset(design_bottom: float, margin: float) -> float:
	return -margin - design_bottom