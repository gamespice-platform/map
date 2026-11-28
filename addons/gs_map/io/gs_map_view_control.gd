class_name GSMapViewControl
extends GSMapEntity

## point_viewcontrol: Enable and Disable send a [code]view_control[/code] event for the game's camera
## ([code]enabled[/code], the camera's [code]at[/code], [code]target[/code] to look at, [code]moveto[/code] path,
## [code]fov[/code], [code]freeze[/code] from spawnflag 4, the activator). A finite [code]wait[/code] (no spawnflag 8)
## ends the view by itself after that many seconds; ending fires OnEndFollow. Nothing is drawn or moved here.

var _active := false


func _input(io: RefCounted, name: String, _param: String, activator: Variant, _caller: Variant) -> bool:
	match name:
		"enable":
			_active = true
			io.event("view_control", {"entity": index, "enabled": true, "at": origin(io), "target": key("target"),
					"moveto": key("moveto"), "fov": key_float("fov", 90.0), "freeze": has_spawnflag(4), "activator": activator})
			var hold := key_float("wait", 10.0)
			if not has_spawnflag(8) and hold > 0.0:
				io.schedule_self(self, "_endview", "", hold)
		"disable", "_endview":
			if not _active:
				return true
			_active = false
			io.event("view_control", {"entity": index, "enabled": false, "activator": activator})
			io.fire(self, "OnEndFollow", activator)
		_:
			return false
	return true
