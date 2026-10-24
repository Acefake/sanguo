extends TextureButton

var role_name := "岗位适性"

func _make_custom_tooltip(description: String) -> Object:
	var presenter := preload("res://scripts/officer_trait_button.gd").new()
	presenter.theme = theme
	presenter.text = role_name
	var panel = presenter._make_custom_tooltip(description)
	presenter.free()
	return panel
