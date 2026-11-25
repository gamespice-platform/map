extends Node3D

## What a converted map's static world costs the renderer, from a fixed camera path: objects, draw calls and primitives per pass, render CPU ms and frame ms.
## Draws the pack as a game does ([GSMapDrawnWorld.attach], props on) under a shadowed sun, then stands at each spawn looking four ways. Run it windowed (tools/render_static_bench.sh).
## Options: --world=<prefix> --models=<model library dir, when the pack's own store is not beside it> --runs=3 --spawns=8 --frames=30 --sun=1 --splits=4 --sun_distance=100, --shot=<dir> (one PNG per view, first run, for a screenshot compare), and any attach option as --opt.<key>=<value> (--opt.batch_props=true).

var _args := {}
var _cam: Camera3D = null
var _vp: RID


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run.call_deferred()


func _arg(key: String, fallback: Variant) -> Variant:
	if not _args.has(key):
		return fallback
	if fallback is bool:
		return str(_args[key]) not in ["0", "false", "off", "no"]
	return type_convert(_args[key], typeof(fallback))


func _run() -> void:
	var got := GSMapBspMesh.load_prefix(str(_arg("world", "")))
	if not got.ok:
		printerr("cannot load: ", got.error)
		get_tree().quit(2)
		return
	var world: GSMapBspMesh = got.value
	if not str(_arg("models", "")).is_empty():
		world.model_library = str(_arg("models", ""))
	var options := {"props": true}
	for key: String in _args:
		if key.begins_with("opt."):
			var parsed: Variant = str_to_var(str(_args[key]))
			options[key.trim_prefix("opt.")] = parsed if parsed != null else _args[key]
	var t := Time.get_ticks_msec()
	var drawn := GSMapDrawnWorld.attach(self, world, options)
	print("STATIC_BENCH build_ms ", Time.get_ticks_msec() - t, " options ", options)
	_add_sun()
	_cam = Camera3D.new()
	_cam.far = 4000.0
	add_child(_cam)
	_cam.make_current()
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	print("STATIC_BENCH scene ", JSON.stringify(census(drawn.root)))
	var props := drawn.root.get_node_or_null("Props")
	if props != null:
		print("STATIC_BENCH props ", JSON.stringify(census(props)), " top_level=", props.get_child_count())
	var views := _views(world)
	if views.is_empty():
		printerr("no spawns to stand at")
		get_tree().quit(3)
		return
	await _frames(30)
	var runs := int(_arg("runs", 3))
	var totals: Array[Dictionary] = []
	for r in runs:
		var sum := {}
		for v: Transform3D in views:
			_cam.global_transform = v
			var got_view := await _measure_view()
			if r == 0 and not str(_arg("shot", "")).is_empty():
				_save_shot(views.find(v))
			for k: String in got_view:
				sum[k] = float(sum.get(k, 0.0)) + float(got_view[k])
		for k: String in sum:
			sum[k] = float(sum[k]) / views.size()
		totals.append(sum)
		print("STATIC_BENCH run ", r, " ", _line(sum))
	print("STATIC_BENCH median views=", views.size(), " runs=", runs, " ", _line(_median(totals)))
	if drawn.visibility != null:
		print("STATIC_BENCH ", drawn.visibility.describe_lines()[0])
	get_tree().quit(0)


func _add_sun() -> void:
	if not bool(_arg("sun", true)):
		return
	var sun := DirectionalLight3D.new()
	sun.name = "BenchSun"
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	sun.shadow_enabled = true
	var modes := [DirectionalLight3D.SHADOW_ORTHOGONAL, DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS]
	sun.directional_shadow_mode = modes[0 if int(_arg("splits", 4)) <= 1 else (1 if int(_arg("splits", 4)) <= 2 else 2)]
	sun.directional_shadow_max_distance = float(_arg("sun_distance", 100.0))
	add_child(sun)


## Each of the first --spawns spawns (in pack order), eye height, looking along its yaw and three quarter turns from it.
func _views(world: GSMapBspMesh) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var spawns: Array = world.manifest.get("spawns", [])
	for s: Variant in spawns.slice(0, int(_arg("spawns", 8))):
		var at: Array = (s as Dictionary).get("at", [])
		if at.size() < 3:
			continue
		var eye := Vector3(float(at[0]), float(at[1]) + 1.6, float(at[2]))
		for turn in 4:
			var b := Basis(Vector3.UP, deg_to_rad(float((s as Dictionary).get("yaw", 0.0)) + 90.0 * turn))
			out.append(Transform3D(b, eye))
	return out


func _save_shot(at: int) -> void:
	var dir := str(_arg("shot", ""))
	DirAccess.make_dir_recursive_absolute(dir)
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(dir.path_join("view_%02d.png" % at))
	if err != OK:
		printerr("cannot save shot ", at, ": ", error_string(err))


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## The mean over --frames frames after a settle, so occlusion and the visibility step have caught up with the new view.
func _measure_view() -> Dictionary:
	await _frames(12)
	var n := int(_arg("frames", 30))
	var out := {}
	var last := Time.get_ticks_usec()
	var vp := get_viewport()
	for i in n:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var row := {
			"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
			"draws": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			"prims": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			"vis_objects": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_OBJECTS_IN_FRAME),
			"vis_draws": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
			"shadow_objects": vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_OBJECTS_IN_FRAME),
			"shadow_draws": vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
			"render_cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(_vp) + RenderingServer.get_frame_setup_time_cpu(),
			"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(_vp),
			"frame_ms": (now - last) / 1000.0,
		}
		last = now
		for k: String in row:
			out[k] = float(out.get(k, 0.0)) + float(row[k]) / n
	return out


func _median(rows: Array[Dictionary]) -> Dictionary:
	var out := {}
	for k: String in rows[0]:
		var vals: Array[float] = []
		for r in rows:
			vals.append(float(r[k]))
		vals.sort()
		out[k] = vals[vals.size() / 2]
	return out


func _line(row: Dictionary) -> String:
	var parts := PackedStringArray()
	for k: String in ["objects", "draws", "prims", "vis_objects", "vis_draws", "shadow_objects", "shadow_draws", "render_cpu_ms", "gpu_ms", "frame_ms"]:
		parts.append("%s=%s" % [k, ("%.3f" if k.ends_with("_ms") else "%.0f") % float(row.get(k, 0.0))])
	return " ".join(parts)


## How the drawn world is made up: geometry instances, their surfaces, multimesh instances, shadow casters, range-culled ones, lights.
static func census(root: Node) -> Dictionary:
	var out := {"mesh_instances": 0, "surfaces": 0, "multimeshes": 0, "multimesh_instances": 0, "lights": 0, "shadow_lights": 0, "casters": 0, "range_culled": 0}
	if root == null:
		return out
	for n in root.find_children("*", "", true, false):
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out["mesh_instances"] += 1
			out["surfaces"] += (n as MeshInstance3D).mesh.get_surface_count()
		elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			out["multimeshes"] += 1
			out["multimesh_instances"] += (n as MultiMeshInstance3D).multimesh.instance_count
		if n is GeometryInstance3D:
			if (n as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				out["casters"] += 1
			if (n as GeometryInstance3D).visibility_range_end > 0.0:
				out["range_culled"] += 1
		if n is Light3D:
			out["lights"] += 1
			if (n as Light3D).shadow_enabled:
				out["shadow_lights"] += 1
	return out
