extends RefCounted
## 存档写盘：在后台线程把存档序列化成 JSON 并原子替换存档文件，主线程只做快照。
##
## 每日推进后的存档约 2.5 MB，JSON.stringify 加写盘约 80 ms，原来都压在主线程那一帧里。
## 格式只去掉了缩进（仍按键排序），读档照旧 JSON.parse_string，新旧存档都能读。
##
## 并发约束：同一时刻最多一个写盘任务（全进程共享）。开始下一次写盘、读任何存档、存档对象退出前，
## 都先 wait()，所以读到的一定是最后一次写完的文件，两次写盘也不会交错。

static var _task := -1


## 等进行中的写盘结束；没有进行中的写盘时立即返回。
static func wait() -> void:
	if _task < 0: return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1


## 在后台把 payload 写进已打开的 file，写完关闭并把 pending 原子替换为 target（都是绝对路径）。
## payload 必须是调用方此后不再改动的独立副本。
static func write(file: FileAccess, pending: String, target: String, payload: Dictionary) -> void:
	wait()
	_task = WorkerThreadPool.add_task(_write.bind(file, pending, target, payload), false, "save")


static func _write(file: FileAccess, pending: String, target: String, payload: Dictionary) -> void:
	file.store_string(JSON.stringify(payload))
	file.flush()
	file.close()
	if DirAccess.rename_absolute(pending, target) != OK:
		push_warning("无法替换进度文件，原存档已保留。")
