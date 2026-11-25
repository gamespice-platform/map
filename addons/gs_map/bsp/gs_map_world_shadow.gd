class_name GSMapWorldShadow
extends RefCounted
## Draws the sun shadows of a converted world's chunks from one shadows-only mesh per [member cell] instead of one per chunk: each chunk's
## position-only proxy ([code]shadow_<chunk>[/code], [method GSMapBspMesh.build_node]) costs a draw per cascade it touches, and on cp-orange-x3
## they were most of the shadow pass's draws once the props were folded ([GSMapPropShadow]).
## [method fold] merges the proxies under a node into per-cell proxies, frees the old ones and points each chunk's meta [code]shadow_proxy[/code] at
## its cell's; the cell keeps meta [code]shadow_members[/code] (the chunks). [GSMapVisibility] calls [method mark] on each change of a chunk's
## drawn or casting state and the cell is shown while any member is on, so a chunk hidden from the camera and out of every light's reach casts
## nothing, and none casts twice.

const CHANNEL := "gs_map.world_shadow"

## Whether [GSMapDrawnWorld] folds a world's chunk shadows (its [code]world_shadow[/code] option overrides it). Wire a cvar to this.
static var enabled: bool = true
## The default [member cell] edge, metres; a [code]world_shadow_cell[/code] option overrides it. Wire a cvar to this.
static var default_cell: float = 32.0

## The edge of a shadow cell, metres. Larger folds more chunks into one draw, but each fold touches more cascades and stays on while any member is.
var cell: float = 32.0

## Chunk proxies the last [method fold] merged, and the cell proxies drawing them.
var folded: int = 0
var proxies: int = 0


## Sets [member enabled] and [member default_cell] for a caller that reaches this script by path (a game's cvars).
static func configure(on: bool, cell_m: float) -> void:
	enabled = on
	if cell_m > 0.0:
		default_cell = cell_m


func _init() -> void:
	cell = default_cell


## Folds the chunk shadow proxies under [param root] into per-cell proxies beside them; returns the number of cell proxies made.
## A cell of one chunk keeps that chunk's own proxy. A no-op when [member cell] is not positive.
func fold(root: Node) -> int:
	folded = 0
	proxies = 0
	if cell <= 0.0 or root == null:
		return 0
	var found: Array[Node] = []
	var centres := PackedVector3Array()
	var low := Vector3.INF   # the grid starts at the lowest centre, so one cell larger than the world folds all of it
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if not n.has_meta(&"shadow_proxy"):   # get_meta's null default still reports a missing key
			continue
		var proxy: Variant = n.get_meta(&"shadow_proxy")
		if not is_instance_valid(proxy) or not proxy is MeshInstance3D or (proxy as Node).get_parent() == null:
			continue
		var p := proxy as MeshInstance3D
		var at := p.transform * p.get_aabb().get_center()
		found.append(n)
		centres.append(at)
		low = low.min(at)
	var cells := {}   # [parent, cell, range end, layers] -> [visual]
	for i in found.size():
		var p := found[i].get_meta(&"shadow_proxy") as MeshInstance3D
		var key := [p.get_parent(), Vector3i(((centres[i] - low) / cell).floor()), p.visibility_range_end, p.layers]
		if not cells.has(key):
			cells[key] = []
		(cells[key] as Array).append(found[i])
	for key: Array in cells:
		var members: Array = cells[key]
		if members.size() < 2:
			continue
		var node := _merge(members, key[1])
		if node == null:
			continue
		(key[0] as Node).add_child(node)
		for v: Node in members:
			var old := v.get_meta(&"shadow_proxy") as Node
			old.get_parent().remove_child(old)
			old.free()
			v.set_meta(&"shadow_proxy", node)
		folded += members.size()
		proxies += 1
	GSLog.debug(CHANNEL, "world shadows folded", {"chunks": folded, "proxies": proxies})
	return proxies


## One shadows-only mesh of the proxies of [param members] in their parent's space, centred on their bounds.
func _merge(members: Array, c: Vector3i) -> MeshInstance3D:
	var box := AABB()
	for i in members.size():
		var p := (members[i] as Node).get_meta(&"shadow_proxy") as MeshInstance3D
		var b := p.transform * p.get_aabb()
		box = b if i == 0 else box.merge(b)
	var centre := box.get_center()
	var verts := PackedVector3Array()
	var index := PackedInt32Array()
	for v: Node in members:
		var p := v.get_meta(&"shadow_proxy") as MeshInstance3D
		var xf := Transform3D(Basis.IDENTITY, -centre) * p.transform
		for s in p.mesh.get_surface_count():
			var a := p.mesh.surface_get_arrays(s)
			var base := verts.size()
			verts.append_array(xf * (a[Mesh.ARRAY_VERTEX] as PackedVector3Array))
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			var at := index.size()
			index.resize(at + idx.size())
			for i in idx.size():
				index[at + i] = base + idx[i]
	if index.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = index
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var first := (members[0] as Node).get_meta(&"shadow_proxy") as MeshInstance3D
	var node := MeshInstance3D.new()
	node.name = "shadow_world_%d_%d_%d" % [c.x, c.y, c.z]
	node.mesh = mesh
	node.position = centre
	node.layers = first.layers
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.visibility_range_end = first.visibility_range_end
	node.set_meta(&"shadow_members", members.duplicate())
	return node


## Marks [param visual] (a chunk with meta [code]shadow_proxy[/code]) on or off for shadows and shows its proxy while it is on or, for a folded
## proxy, while any member is (a member never marked counts as on).
static func mark(visual: Node, on: bool) -> void:
	visual.set_meta(&"shadow_on", on)
	var proxy: Variant = visual.get_meta(&"shadow_proxy") if visual.has_meta(&"shadow_proxy") else null
	if not is_instance_valid(proxy):
		return
	var p := proxy as Node3D
	if not on and p.has_meta(&"shadow_members"):
		for m: Variant in p.get_meta(&"shadow_members"):
			if is_instance_valid(m) and bool((m as Node).get_meta(&"shadow_on", true)):
				on = true
				break
	p.visible = on
