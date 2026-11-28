class_name GSMapWeaponStrip
extends GSMapEntity

## player_weaponstrip: Strip, StripWeaponsAndSuit, StripActiveWeapon and StripWeaponByClassName take the activator's weapons. The game owns inventories, so this
## sends a [code]strip[/code] event ([code]activator[/code], [code]suit[/code] for the second, and [code]only[/code]: "active" for
## StripActiveWeapon, the class for StripWeaponByClassName, else empty for all) and the game empties it.


func _input(io: RefCounted, name: String, param: String, activator: Variant, _caller: Variant) -> bool:
	match name:
		"strip", "stripweaponsandsuit", "stripactiveweapon", "stripweaponbyclassname":
			if enabled:
				io.event("strip", {"entity": index, "activator": activator, "suit": name == "stripweaponsandsuit",
						"only": "active" if name == "stripactiveweapon" else (param if name == "stripweaponbyclassname" else "")})
		_:
			return false
	return true
