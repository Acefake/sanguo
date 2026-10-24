extends SceneTree
## 确定性随机与上限：同 key 同值、落在 [0,1)、分布大致均匀；数值通道与 bias 按 R3/R4 夹取。
##
##   godot --headless --path . --script res://tests/people/rng_caps_validation.gd

const Rng = preload("res://scripts/people/rng.gd")
const Caps = preload("res://scripts/people/caps.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _initialize() -> void:
	var key := Rng.key(1910901, 7201, "p_001", "allegiance")
	check(key == "1910901:7201:p_001:allegiance", "key 格式：种子:旬号:人物:用途")
	check(Rng.roll(key) == Rng.roll(key), "同 key 同值")
	check(Rng.roll(key) != Rng.roll(Rng.key(1910901, 7202, "p_001", "allegiance")), "旬号不同结果不同")
	var total := 0.0
	var samples := 4000
	for index in samples:
		var value := Rng.roll("sample:%d" % index)
		check(value >= 0.0 and value < 1.0, "roll 应在 [0,1)")
		total += value
	check(absf(total / samples - 0.5) < 0.02, "均值应接近 0.5，实际 %.3f" % (total / samples))
	check(not Rng.chance(key, 0.0) and Rng.chance(key, 1.0), "chance 边界")

	check(Caps.clamp_value("attribute_point", 9.0) == 6.0 and Caps.clamp_value("attribute_point", -9.0) == -6.0, "属性点 ±6")
	check(is_equal_approx(Caps.clamp_value("percent", 0.3), 0.10) and is_equal_approx(Caps.clamp_value("pp", -0.2), -0.05), "相对 ±10%、概率 ±5pp")
	check(Caps.bias([20.0]) == 15.0 and Caps.bias([12.0, 12.0, 12.0]) == 30.0 and Caps.bias([-20.0, 5.0]) == -10.0, "bias 单来源 ±15、合计 ±30")

	print("PEOPLE_RNG_CAPS: %s（%d 处失败）" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(1 if not failures.is_empty() else 0)
