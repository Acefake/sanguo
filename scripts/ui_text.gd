extends RefCounted

static func clean(value: String) -> String:
	return value.replace("·", "  ").replace("•", "  ").replace("・", "  ")
