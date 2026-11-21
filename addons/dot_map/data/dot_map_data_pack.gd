class_name GSMapDataPack
extends GSMapDataFile

## The bundle shipped inside a map's pack: the layout of [GSMapDataFile] under the pack's mount, read-only.


func _init(p_root: String = "res://map_data") -> void:
	root = p_root


func save(_bundle: GSMapDataBundle, _by: String = "") -> GSResult:
	return GSResult.fail(GSError.CODE_FORBIDDEN, "A pack's map data is read-only.")


func remove(_game: String, _map_id: String, _map_version: String) -> GSResult:
	return GSResult.fail(GSError.CODE_FORBIDDEN, "A pack's map data is read-only.")
