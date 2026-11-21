extends "tests_cloud.gd"

## The map data bundle and its stores: round trip, layering, stale fallback and hostile imports.


func _bundle(version: String = "1.0.0", sections: Dictionary = {"spawns": {"points": [{"id": "a", "pos": [1.0, 2.0, 3.0]}]}}) -> GSMapDataBundle:
	var b := GSMapDataBundle.new()
	b.game = "game-x"
	b.map_id = "surf_a"
	b.map_version = version
	b.digest = "abc"
	b.meta = {"author": "me"}
	b.sections = sections
	return b


func _json(patch: Dictionary) -> String:
	var d := _bundle().to_dict()
	d.merge(patch, true)
	return JSON.stringify(d)


func _test_data_round_trip() -> void:
	_section("map data round trip")
	var b := _bundle()
	var mem := GSMapDataMemory.new()
	_check((await mem.save(b, "t")).ok, "memory store saves")
	var got: GSResult = await mem.fetch("game-x", "surf_a", "1.0.0")
	_check(got.ok and got.value.sections == b.sections and got.value.meta == b.meta and got.value.digest == "abc" and not got.value.stale, "memory store gives it back equal")
	var dir := "user://map_data_test_%d" % Time.get_ticks_usec()
	var file := GSMapDataFile.new(dir)
	_check((await file.save(b, "t")).ok and FileAccess.file_exists(dir + "/game-x/surf_a/1.0.0.json"), "file store writes <game>/<map>/<version>.json")
	got = await file.fetch("game-x", "surf_a", "1.0.0")
	_check(got.ok and got.value.to_dict() == b.to_dict(), "file store reads it back equal")
	_check((await file.versions("game-x", "surf_a")).value == PackedStringArray(["1.0.0"]), "versions lists it")
	_check((await file.remove("game-x", "surf_a", "1.0.0")).ok and (await file.fetch("game-x", "surf_a", "1.0.0")).code() == GSMapDataStore.NOT_FOUND, "remove deletes it and a load is then not_found")
	_check((await file.fetch("game-x", "../x", "1.0.0")).code() == GSError.CODE_INVALID and (await mem.save(_bundle("1.0.0/../x"))).code() == GSError.CODE_INVALID, "an id with a separator is refused before any path is built")
	_check(GSMapDataBundle.from_json(b.to_json().value).value.to_dict() == b.to_dict(), "to_json then from_json is the identity")
	var big := _bundle("1.0.0", {"spawns": {"s": "x".repeat(2000)}})
	_check((await mem.save(big)).code() == GSError.CODE_INVALID, "export refuses what an import would")
	_done()


func _test_data_layering() -> void:
	_section("map data layering")
	var pack := GSMapDataMemory.new()
	var store := GSMapDataMemory.new()
	var _p := await pack.save(_bundle("1.0.0", {"spawns": {"v": "pack"}, "cull": {"v": "pack"}}))
	var _s := await store.save(_bundle("1.0.0", {"spawns": {"v": "store"}, "nav_links": {"v": "store"}}))
	var r: GSResult = await GSMapDataStore.read_layered(pack, store, "game-x", "surf_a", "1.0.0")
	var s: Dictionary = r.value.sections if r.ok else {}
	_check(r.ok and s.get("spawns", {}).get("v") == "store", "the store overrides the pack's section")
	_check(s.get("cull", {}).get("v") == "pack" and s.get("nav_links", {}).get("v") == "store", "sections only one side has are kept")
	_check((await GSMapDataStore.read_layered(pack, GSMapDataMemory.new(), "game-x", "surf_a", "1.0.0")).value.sections["spawns"]["v"] == "pack", "an empty store leaves the pack's data")
	_check((await GSMapDataStore.read_layered(null, null, "game-x", "surf_a", "1.0.0")).code() == GSMapDataStore.NOT_FOUND, "nothing anywhere is not_found")
	var ro := GSMapDataPack.new("user://nowhere")
	_check((await ro.save(_bundle())).code() == GSError.CODE_FORBIDDEN and (await ro.remove("game-x", "surf_a", "1.0.0")).code() == GSError.CODE_FORBIDDEN, "a pack store is read-only")
	_done()


func _test_data_stale() -> void:
	_section("map data stale fallback")
	var mem := GSMapDataMemory.new()
	for v in ["1.0.0", "1.2.0", "2.0.0"]:
		var _r := await mem.save(_bundle(v, {"spawns": {"v": v}}))
	var r: GSResult = await mem.fetch("game-x", "surf_a", "1.5.0")
	_check(r.ok and r.value.map_version == "1.2.0" and r.value.stale, "an edited map gets the newest older data, marked stale", str(r.value.map_version if r.ok else r.error))
	_check((await mem.fetch("game-x", "surf_a", "0.9.0")).code() == GSMapDataStore.NOT_FOUND, "data only for newer versions is not used")
	_check(not (await mem.fetch("game-x", "surf_a", "2.0.0")).value.stale, "an exact match is not stale")
	_check((await mem.versions("game-x", "surf_a")).value == PackedStringArray(["1.0.0", "1.2.0", "2.0.0"]), "versions are in semver order")
	var layered: GSResult = await GSMapDataStore.read_layered(null, mem, "game-x", "surf_a", "1.5.0")
	_check(layered.ok and layered.value.stale, "stale survives layering")
	_done()


func _test_data_hostile_import() -> void:
	_section("map data hostile import")
	var ok := GSMapDataBundle.import_json(_json({}), "surf_a", "1.0.0", "abc")
	_check(ok.ok, "a matching file imports")
	_check(GSMapDataBundle.import_json(_json({}), "surf_b", "1.0.0", "abc", true).code() == GSError.CODE_CONFLICT, "a different map id is refused even with force")
	_check(GSMapDataBundle.import_json(_json({}), "surf_a", "2.0.0", "abc").code() == GSError.CODE_CONFLICT, "a different version needs force")
	_check(GSMapDataBundle.import_json(_json({}), "surf_a", "2.0.0", "abc", true).ok, "and force takes it")
	_check(GSMapDataBundle.import_json(_json({}), "surf_a", "1.0.0", "zzz").code() == GSError.CODE_CONFLICT, "a different geometry digest needs force")
	_check(GSMapDataBundle.from_json("not json").code() == GSError.CODE_PARSE and GSMapDataBundle.from_json(_json({"format": "other"})).code() == GSError.CODE_INVALID, "garbage and the wrong format are refused")
	_check(GSMapDataBundle.from_json(_json({"schema": 2})).code() == GSError.CODE_VERSION, "a newer schema is refused")
	var unknown := GSMapDataBundle.from_json(_json({"sections": {"spawns": {}, "evil": {"x": 1}}}))
	_check(unknown.ok and unknown.value.sections.keys() == ["spawns"], "unknown sections are dropped")
	_check(GSMapDataBundle.from_json(_json({"sections": {"spawns": {"script": "res://evil.gd"}}})).code() == GSError.CODE_INVALID, "a resource path is refused")
	_check(GSMapDataBundle.from_json(_json({"sections": {"spawns": {"s": "evil.gd"}}})).code() == GSError.CODE_INVALID, "a script name is refused")
	_check(GSMapDataBundle.from_json(_json({"sections": {"spawns": {"s": "x".repeat(2000)}}})).code() == GSError.CODE_INVALID, "a long string is refused")
	var deep: Variant = "leaf"
	for i in 20:
		deep = {"d": deep}
	_check(GSMapDataBundle.from_json(_json({"sections": {"spawns": deep}})).code() == GSError.CODE_INVALID, "deep nesting is refused")
	var wide: Array = []
	wide.resize(GSMapDataBundle.MAX_NODES + 1)
	wide.fill(1)
	_check(GSMapDataBundle.from_json(_json({"sections": {"spawns": {"p": wide}}})).code() == GSError.CODE_INVALID, "too many values are refused")
	_check(GSMapDataBundle.from_json(_json({"game": "../up"})).code() == GSError.CODE_INVALID, "an id that would climb out of the directory is refused")
	_check(GSMapDataBundle.from_json(_json({"sections": {"spawns": [1]}})).code() == GSError.CODE_INVALID, "a section that is not an object is refused")
	_done()
