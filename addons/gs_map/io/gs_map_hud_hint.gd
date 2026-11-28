class_name GSMapHudHint
extends GSMapEntity

## env_hudhint: ShowHudHint and HideHudHint send a [code]hud_hint[/code] event (the message key, [code]show[/code],
## the activator, and [code]all_players[/code] from spawnflag 1) for the game's HUD; SetHudHint changes the message. Nothing is drawn here.


func _input(io: RefCounted, name: String, param: String, activator: Variant, _caller: Variant) -> bool:
	match name:
		"showhudhint", "hidehudhint":
			io.event("hud_hint", {"entity": index, "message": key("message"), "show": name == "showhudhint",
					"all_players": has_spawnflag(1), "activator": activator})
		"sethudhint":
			keys["message"] = param
		_:
			return false
	return true
