class_name GSMapTriggerSoundscape
extends GSMapEntity

## trigger_soundscape: a body that enters the volume hears the [code]env_soundscape_triggerable[/code]
## its [code]soundscape[/code] key names, wherever it stands, until it leaves. [GSMapVolumes] then reports
## the change through the usual [code]soundscape[/code] event.


func body_enter(io: RefCounted, info: Dictionary) -> void:
	if enabled:
		_listen(io, info, true)


func body_leave(io: RefCounted, info: Dictionary) -> void:
	_listen(io, info, false)


func _enabled_changed(_io: RefCounted, on: bool) -> void:
	if not on:
		for e: GSMapEntity in _targets(_io):
			(e as GSMapSoundscape).listeners.clear()


func _targets(io: RefCounted) -> Array:
	var out: Array = []
	for e: GSMapEntity in io.find(key("soundscape")):
		if e is GSMapSoundscape:
			out.append(e)
	return out


func _listen(io: RefCounted, info: Dictionary, on: bool) -> void:
	for e: GSMapSoundscape in _targets(io):
		if on:
			e.listeners[info["id"]] = true
		else:
			e.listeners.erase(info["id"])
