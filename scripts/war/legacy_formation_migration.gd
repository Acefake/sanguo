extends RefCounted

# Retired commands must not retain a hidden movement/attack lock after loading.
static func apply(state: Dictionary) -> void:
	for collection in ["armies", "corps"]:
		for entry in state.get(collection, {}).values():
			for field in ["formation", "formation_changed_at", "formation_skill", "formation_locked", "formation_contact_days", "formation_progress"]:
				entry.erase(field)
			if entry.get("action", {}).get("type", "") == "set_formation": entry["action"] = {"type":"hold"}
			entry.get("action", {}).erase("formation")
			for order in entry.get("orders", []) if entry.get("orders", []) is Array else []:
				order.get("action", {}).erase("formation")
			if entry.has("orders") and entry["orders"] is Array:
				entry["orders"] = entry["orders"].filter(func(order): return order.get("action", {}).get("type", "") != "set_formation")
