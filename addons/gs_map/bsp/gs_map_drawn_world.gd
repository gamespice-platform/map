class_name GSMapDrawnWorld
extends RefCounted
## A converted world pack drawn over a game's own collision: the pack's meshes, lightmap, probes and culling, and nothing that collides, moves or plays.
##
## For a game whose map is its own document (boxes, doors, props) and wants the converted art on top: the document stays what everything stands on, this is only what is seen.

const CHANNEL := "gs_map.drawn"

## The pack drawn; null until [method attach].
var world: GSMapBspMesh = null
## The drawn node ("World"), its transform the pack's frame in the game's.
var root: Node3D = null
## Drives the ambient from the bake; null when the world is not drawn lightmapped.
var lit: GSMapLitWorld = null
## The culling node; null headless or for a pack without visibility data.
var visibility: GSMapVisibility = null
## [method GSMapCredits.line] of the pack: its author and the art whose licence asks for a name.
var credits: String = ""


## Reads the pack at [param prefix] and fetches the art slice its licence names ([GSMapStore]); the value is the [GSMapBspMesh]. A slice that cannot be had is only a warning: generic art is drawn.
static func read(prefix: String, cloud: Object = null) -> GSResult:
	var got := GSMapBspMesh.load_prefix(prefix)
	if not got.ok:
		return got
	var world: GSMapBspMesh = got.value
	var stored: GSResult = await GSMapStore.ensure(world.licence(), cloud, "", world.source_path.get_base_dir())
	if not stored.ok:
		GSLog.debug(CHANNEL, "a world's art slice could not be fetched; GSMapStore.apply warns once", {"at": prefix, "why": stored.error.message})
	return GSResult.success(world)


## Draws [param world] under [param parent]. [code]options.original_textures[/code] (default false) draws the map's own
## textures ([member GSMapSurfaces.use_original_textures]); pass [method GSMapLocalMaps.is_original] of a local entry, never true for a published map.
## [code]options.props[/code] draws the pack's props; [code]options.batch_props[/code] (default false: no measured gain on Fork yet) draws the static ones in batches ([GSMapPropBatch]: [code]batch_cell[/code], [code]batch_max_tris[/code], [code]instance_cell[/code]).
## [code]options.prop_shadow[/code] (default true, never headless) draws the props' sun shadows per cell ([GSMapPropShadow]: [code]prop_shadow_cell[/code], [code]prop_shadow_max_tris[/code]).
static func attach(parent: Node3D, world: GSMapBspMesh, options: Dictionary = {}) -> GSMapDrawnWorld:
	var surfaces := _surfaces_for(world, options)
	var node := world.build_node(surfaces.world_material_for(world, world.source_path.get_base_dir()))
	return _finish(parent, world, options, surfaces, node)


## [method attach] that pauses on [param slice] throughout: the texture decode, each surface's material, the mesh batches and each finishing step (probes, props, lighting, culling) yield a frame once the budget is spent, so a loading cover keeps animating and no one frame holds the build.
## Null when [param parent] was freed during the build (the map was swapped away); the built meshes are freed with it.
## [code]options["mark"][/code], a [code]func(label: String)[/code], is told as each step ends ("drawn: materials", "drawn: meshes", "drawn: hang" ...) and of any one material dearer than [constant GSMapSurfaces.SLOW_MATERIAL_USEC], so a game's frame trace can name the step a long frame was spent in.
static func attach_async(parent: Node3D, world: GSMapBspMesh, options: Dictionary, slice: GSFrameSlice) -> GSMapDrawnWorld:
	var mark: Callable = options.get("mark", Callable())
	var surfaces := _surfaces_for(world, options)
	surfaces.on_step = mark
	var material_for: Callable = await surfaces.world_material_for_async(world, world.source_path.get_base_dir(), slice.budget_ms)
	_tell(mark, "drawn: materials")
	var node: Node3D = await world.build_node_async(material_for, true, false, slice)
	_tell(mark, "drawn: meshes")
	if not is_instance_valid(parent):
		GSLog.debug(CHANNEL, "the world's parent went away during the build; dropped", {"name": str(world.manifest.get("name", ""))})
		if node != null:
			node.free()
		return null
	var drawn := GSMapDrawnWorld.new()
	var names := ["hang", "probes", "props", "lit", "culling"]
	var at := 0
	for step: Callable in _finish_steps(parent, world, options, surfaces, node, drawn, slice):
		if slice.due():
			await slice.pause()
		if not is_instance_valid(parent):
			GSLog.debug(CHANNEL, "the world's parent went away while it was finished; dropped", {"name": str(world.manifest.get("name", ""))})
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()
			return null
		await step.call()
		_tell(mark, "drawn: " + names[at])
		at += 1
	if not is_instance_valid(parent):
		return null
	_log_drawn(drawn)
	return drawn


static func _tell(mark: Callable, label: String) -> void:
	if mark.is_valid():
		mark.call(label)


static func _surfaces_for(world: GSMapBspMesh, options: Dictionary) -> GSMapSurfaces:
	var surfaces := GSMapSurfaces.new(str(options.get("surfaces_root", GSMapSurfaces.DEFAULT_ROOT)))
	surfaces.use_lightmap = bool(options.get("lightmap", true))
	surfaces.use_original_textures = bool(options.get("original_textures", false))
	GSMapTextureTier.apply_current(surfaces)
	GSMapStore.apply(world.licence(), options.get("cloud"), surfaces, world)
	if bool(options.get("one_way_glass", true)) and not world.glass_material_for.is_valid():
		var cell := GSMapOneWayGlass.cell_of(world.manifest)
		if not cell.is_empty():
			world.glass_material_for = GSMapOneWayGlass.hook(cell["centre"], cell["radius"])
	return surfaces


static func _finish(parent: Node3D, world: GSMapBspMesh, options: Dictionary, surfaces: GSMapSurfaces, node: Node3D) -> GSMapDrawnWorld:
	var drawn := GSMapDrawnWorld.new()
	for step: Callable in _finish_steps(parent, world, options, surfaces, node, drawn):
		step.call()
	_log_drawn(drawn)
	return drawn


## What follows the mesh build, one callable per step so [method attach_async] can yield between them: prune to the world and hang it under [param parent], the probes, the props, the lighting, the culling.
## With a [param slice] the props step also yields between props, so it must be awaited.
static func _finish_steps(parent: Node3D, world: GSMapBspMesh, options: Dictionary, surfaces: GSMapSurfaces, node: Node3D, drawn: GSMapDrawnWorld, slice: GSFrameSlice = null) -> Array[Callable]:
	return [
		func() -> void: _hang(parent, world, options, node, drawn),
		func() -> void: _add_probes(world, options, node),
		func() -> void: await _add_props(world, options, node, slice),
		func() -> void: _add_lit(parent, world, options, surfaces, node, drawn),
		func() -> void: _add_culling(parent, world, options, node, drawn),
	]


static func _hang(parent: Node3D, world: GSMapBspMesh, options: Dictionary, node: Node3D, drawn: GSMapDrawnWorld) -> void:
	drawn.world = world
	drawn.credits = GSMapCredits.line(world.manifest)
	node.name = "World"
	if bool(options.get("only_world", true)):
		var glass := {}
		# Drawn glass is solid only through a GSMapGlass pane; a caller that builds none must not draw it.
		for rec: Dictionary in (world.breakables() if bool(options.get("keep_glass", false)) else []):
			if rec.get("model") != null:
				glass[int(rec["model"])] = true
		for child in node.get_children():
			if String(child.name) == "world":
				continue
			if child.has_meta(&"model") and glass.has(int(child.get_meta(&"model"))):
				child.add_to_group(GSMapGlass.VISUAL_GROUP)
				continue
			node.remove_child(child)
			child.free()
	node.transform = options.get("transform", Transform3D.IDENTITY)
	parent.add_child(node)
	drawn.root = node


static func _add_probes(world: GSMapBspMesh, options: Dictionary, node: Node3D) -> void:
	var probes := int(options.get("probes", 8))
	if probes <= 0:
		return
	var env_node := world.build_environment(probes, false)
	if env_node == null:
		return
	var found := env_node.get_node_or_null("Probes")
	if found != null:
		env_node.remove_child(found)
		node.add_child(found)
	env_node.free()


static func _add_props(world: GSMapBspMesh, options: Dictionary, node: Node3D, slice: GSFrameSlice = null) -> void:
	if not bool(options.get("props", false)):
		return
	var props: Node3D
	if slice == null:
		props = world.build_props()
	else:
		props = await world.build_props_async(slice)
	if not is_instance_valid(node):
		props.free()
		return
	if props.get_child_count() == 0:
		props.free()
		return
	# Static props drawn in batches: small ones baked per cell, copies of larger ones instanced (GSMapPropBatch).
	if bool(options.get("batch_props", false)):
		var batcher := GSMapPropBatch.new()
		batcher.cell = float(options.get("batch_cell", batcher.cell))
		batcher.max_tris = int(options.get("batch_max_tris", batcher.max_tris))
		batcher.instance_cell = float(options.get("instance_cell", batcher.instance_cell))
		batcher.batch(props)
	# Their sun shadows drawn from one shadows-only mesh per cell (GSMapPropShadow), not one per prop mesh per cascade.
	if bool(options.get("prop_shadow", true)) and DisplayServer.get_name() != "headless":
		var shadows := GSMapPropShadow.new()
		shadows.cell = float(options.get("prop_shadow_cell", shadows.cell))
		shadows.max_tris = int(options.get("prop_shadow_max_tris", shadows.max_tris))
		shadows.fold(props)
	node.add_child(props)


static func _add_lit(parent: Node3D, world: GSMapBspMesh, options: Dictionary, surfaces: GSMapSurfaces, node: Node3D, drawn: GSMapDrawnWorld) -> void:
	var env: Environment = options.get("environment")
	if env != null:
		drawn.lit = GSMapLitWorld.attach(parent, world, env, options.get("lamps", []), surfaces.use_lightmap, node)


static func _add_culling(parent: Node3D, world: GSMapBspMesh, options: Dictionary, node: Node3D, drawn: GSMapDrawnWorld) -> void:
	if not bool(options.get("cull", true)) or DisplayServer.get_name() == "headless":
		return
	var vis := GSMapVisibility.new()
	vis.name = "Visibility"
	parent.add_child(vis)
	var res := vis.setup(world, node)
	if res.ok:
		drawn.visibility = vis
	else:
		GSLog.debug(CHANNEL, "the world is drawn without culling", {"why": res.error.message})
		vis.queue_free()


static func _log_drawn(drawn: GSMapDrawnWorld) -> void:
	GSLog.debug(CHANNEL, "world drawn", {"name": str(drawn.world.manifest.get("name", "")), "lit": drawn.lit != null, "culled": drawn.visibility != null})


## Takes the drawn world out again: the node, the ambient driver and the culling.
func detach() -> void:
	for n: Node in [root, lit, visibility]:
		if is_instance_valid(n):
			n.queue_free()
	root = null
	lit = null
	visibility = null


func describe() -> String:
	return "drawn world %s: %s, lit %s, culled %s" % [
		str(world.manifest.get("name", "")) if world != null else "none",
		"attached" if is_instance_valid(root) else "detached", lit != null, visibility != null]
