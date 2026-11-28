extends "tests_batch.gd"

const TOGGLE_FIXTURE := "res://examples/bsp_mesh/fixture"

## The toggled-brush collision section of the bsp mesh suite.


## Under movers_only a func_brush keeps its col_* bodies (the io flips their layers, and a game finds them by
## name to release the legacy hull); a plain brush entity and the world model do not.
func _test_toggle_collision() -> void:
	_section("movers_only keeps the collision bodies of a toggled brush")
	var dir := "user://toggle_col"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TOGGLE_FIXTURE + ".json"))
	doc["movers"] = []
	var f := FileAccess.open(dir + "/fixture.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	DirAccess.copy_absolute(TOGGLE_FIXTURE + ".bin", dir + "/fixture.bin")
	var brush := {"index": 9, "classname": "func_brush", "targetname": "jdoor", "parentname": "", "outputs": [], "pairs": [["model", "*1"]]}
	var plain := {"index": 9, "classname": "func_detail_made_up", "targetname": "x", "parentname": "", "outputs": [], "pairs": [["model", "*1"]]}
	var with_brush := _movers_only_world(dir + "/fixture", brush)
	var no_brush := _movers_only_world(dir + "/fixture", plain)
	_check(with_brush != null and _col_bodies(with_brush, 1) > 0, "a func_brush model has a col_ body under movers_only")
	_check(no_brush != null and _col_bodies(no_brush, 1) == 0, "an unknown brush entity's model has none")
	_check(with_brush != null and _col_bodies(with_brush, 0) == 0, "the world model still has none")
	var body := with_brush.visual.find_child("col_solid", true, false) as CollisionObject3D if with_brush != null else null
	_check(body != null and body.collision_layer != 0, "the body is solid until the io disables it")
	for w: Node in [with_brush, no_brush]:
		if w != null:
			w.free()
	_done()


func _movers_only_world(prefix: String, ent: Dictionary) -> GSMapWorld:
	var src := {"format": "gs-bsp-source", "version": 1, "entities": [ent]}
	var r := GSMapWorld.build(prefix, {}, {"doc": src, "environment": false, "draw": true, "movers_only": true})
	return r.value as GSMapWorld if r.ok else null


func _col_bodies(w: GSMapWorld, model: int) -> int:
	var n := 0
	for c in w.visual.get_children():
		if int(c.get_meta(&"model", -1)) == model:
			n += c.find_children("col_*", "CollisionObject3D", true, false).size()
	return n
