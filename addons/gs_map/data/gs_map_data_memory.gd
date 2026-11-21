class_name GSMapDataMemory
extends GSMapDataStore

## Bundles held as JSON text, so a load is a copy. For tests and for a server that keeps nothing.

var _held: Dictionary = {}  # "game/map" -> {version: text}


func fetch(game: String, map_id: String, map_version: String) -> GSResult:
	var bad := check_key(game, map_id, map_version)
	if bad != null:
		return bad
	var by_ver: Dictionary = _held.get(game + "/" + map_id, {})
	var v := pick_version(PackedStringArray(by_ver.keys()), map_version)
	if v == "":
		return GSResult.fail(NOT_FOUND, "No data for %s %s." % [map_id, map_version])
	var res := GSMapDataBundle.from_json(by_ver[v])
	if res.ok:
		res.value.stale = v != map_version
	return res


func save(bundle: GSMapDataBundle, by: String = "") -> GSResult:
	var text := bundle.to_json()
	if not text.ok:
		return text
	var key := bundle.game + "/" + bundle.map_id
	if not _held.has(key):
		_held[key] = {}
	_held[key][bundle.map_version] = text.value
	GSLog.info("map_data", "%s saved %s %s" % [by, bundle.map_id, bundle.map_version])
	return GSResult.success(bundle)


func versions(game: String, map_id: String) -> GSResult:
	var bad := check_key(game, map_id)
	if bad != null:
		return bad
	return GSResult.success(sort_versions(_held.get(game + "/" + map_id, {}).keys()))


func remove(game: String, map_id: String, map_version: String) -> GSResult:
	var bad := check_key(game, map_id, map_version)
	if bad != null:
		return bad
	if not _held.get(game + "/" + map_id, {}).erase(map_version):
		return GSResult.fail(NOT_FOUND, "No data for %s %s." % [map_id, map_version])
	return GSResult.success()
