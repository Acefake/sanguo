class_name PeopleRng
extends RefCounted
## 人物系统的确定性随机（00-总览 R6）。
##
## 同一个 key 永远得到同一个数，与调用顺序、平台、引擎版本无关：数值取自 key 的 SHA-256 前 32 位。
## key 由种子、旬号、人物 id、用途拼成，人物系统里所有随机都必须经过这里，不用全局 randf()。
## 不保存状态，不需要存档。


## 拼出标准 key：种子:旬号:人物:用途。
static func key(seed: int, xun: int, person_id: String, purpose: String) -> String:
	return "%d:%d:%s:%s" % [seed, xun, person_id, purpose]


## [0, 1) 之间的均匀数。
static func roll(roll_key: String) -> float:
	return float(roll_key.sha256_text().left(8).hex_to_int()) / 4294967296.0


## 概率 p 是否命中。
static func chance(roll_key: String, p: float) -> bool:
	return roll(roll_key) < p
