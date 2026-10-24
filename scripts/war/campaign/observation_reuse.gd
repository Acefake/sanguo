extends RefCounted
## _observe_all 的城池情报复用：一天两次刷新之间城池没有变化时，沿用部队上一份城池情报，不再深拷贝。
##
## 每支部队都要一份全部城池情报的深拷贝（全图可见，各部队内容相同），19 支部队约 8 ms。
## 早上那次刷新与前一晚只差 observed_at（日期变了），必须重建；晚上那次与早上通常逐项相同。
##
## 复用条件（每次刷新都核对，不靠写入方通知）：部队上一份城池情报与本次新算的逐键、逐值相等，
## 且键的顺序相同。不满足就照原样深拷贝。复用的只是城池表这一个容器，情报外层字典和敌情每次照旧新建。


## 部队这次应得的城池情报：与上一份相同就返回上一份，否则返回 fresh 的深拷贝。
static func cities_for(previous_intel, fresh: Dictionary) -> Dictionary:
	if previous_intel is Dictionary:
		var previous = previous_intel.get("cities")
		if previous is Dictionary and previous.size() == fresh.size() and previous.keys() == fresh.keys() and previous == fresh:
			return previous
	return fresh.duplicate(true)
