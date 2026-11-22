extends Node

## [GSMapTextureTier]: video quality picks the texture cap, and the browser quota steps it down loudly.

var _passed := 0
var _failed := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", what)


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	print("gs-map texture tier")
	var s := GSMapSurfaces.new()
	var r := GSMapTextureTier.apply(s, 0)
	_check(s.max_texture_size == 512 and s.half_res_masks and s.half_res_normals and r["quality"] == 0, "low caps at 512")
	GSMapTextureTier.apply(s, 1)
	_check(s.max_texture_size == 1024, "medium caps at 1024")
	GSMapTextureTier.apply(s, 3)
	_check(s.max_texture_size == 0 and not s.half_res_masks and not s.half_res_normals, "ultra is unlimited, full masks")
	_check(GSMapTextureTier.apply(s, 3, 1 << 30, -1)["quality"] == 3, "unmeasured free space never steps down")
	var gib := 1 << 30
	var f := GSMapTextureTier.fit(2, int(1.5 * gib), 760 * (1 << 20))
	_check(f["quality"] == 1 and f["fits"], "1.5 GiB of art in 760 MiB drops high to medium: %s" % f)
	f = GSMapTextureTier.fit(2, 10 * gib, 100 * (1 << 20))
	_check(f["quality"] == 0 and not f["fits"], "hopeless art lands on low and reports it does not fit: %s" % f)
	f = GSMapTextureTier.fit(2, 10 * gib, 100)
	GSMapTextureTier.quota_share = 0.0
	_check(GSMapTextureTier.fit(2, 10 * gib, 100)["quality"] == 2, "quota_share 0 turns the check off")
	GSMapTextureTier.quota_share = 0.8
	var before := s.max_texture_size
	_check(GSMapTextureTier.apply(s, 9).is_empty() and s.max_texture_size == before, "a bad level is refused and changes nothing")
	var saved := GSMapTextureTier.max_sides
	GSMapTextureTier.max_sides = [1, 2] as Array[int]
	_check(GSMapTextureTier.settings(0).is_empty(), "a short table is refused")
	GSMapTextureTier.max_sides = saved
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
