class_name GSMapVisibility
extends Node

## Draws only what the camera could see, from a converted map's precomputed visibility: [code]vis.setup(world, world_node)[/code] in the scene, [code]vis.set_door_open(name, true)[/code] opens a door's area portals.
## The camera's cluster, not the frustum: a chunk is drawn when one of its clusters is in the union of the PVS rows around the camera and in an area reachable through open portals; the set is looked up again every [member move_step]. Occluders hide props and characters behind walls.
## Nothing runs on a headless host unless [member run_headless] is set.

const CHANNEL := "gs_map.visibility"

enum Mode { OFF, PVS, OCCLUDERS, BOTH }
enum Shadows { NONE, ALL, REACHING }

## Metres a chunk is assumed to throw a sun shadow.
const SUN_SWEEP := 2000.0
const MODE_NAMES := {"off": Mode.OFF, "pvs": Mode.PVS, "occluders": Mode.OCCLUDERS, "both": Mode.BOTH}

signal clusters_changed(camera_clusters: PackedInt32Array)

## off, pvs, occluders or both ([method parse_mode]); a part the map has no data for is skipped.
@export var mode: Mode = Mode.BOTH
## The camera to follow; unset follows the viewport's current camera.
@export var camera_ref: GSNodeRef = null
## Metres round the camera whose clusters count as its own, so crossing a leaf never shows a frame late.
@export var margin: float = 1.0
## Metres the camera moves before its clusters are looked up again.
@export var move_step: float = 0.25
## What a chunk hidden by the PVS still does: NONE disappears (light leaks where it shaded), ALL is drawn shadow-only, REACHING is drawn
## shadow-only only while a shadow-casting light that touches a drawn chunk reaches it.
@export var shadows: Shadows = Shadows.REACHING
## Metres past which a world chunk is not drawn: below 0 the map's own fog far plane, 0 never.
@export var chunk_view_distance: float = -1.0
@export var run_headless: bool = false

var world: GSMapBspMesh = null
var root: Node3D = null

var _planes := PackedFloat32Array()
var _nodes := PackedInt32Array()
var _leaf_cluster := PackedInt32Array()
var _cluster_area := PackedInt32Array()
var _pvs_offsets := PackedInt32Array()
var _pvs := PackedByteArray()
var _head: int = -1
var _clusters: int = 0
var _row_bytes: int = 0
## [{node, clusters: PackedInt32Array, shown: bool}]
var _items: Array[Dictionary] = []
var _portals: Array = []
var _portal_open := {}
var _portal_targets := {}
var _occluder: OccluderInstance3D = null
var _viewport_had_occlusion: bool = false
var _last_pos := Vector3.INF
var _camera_clusters := PackedInt32Array()
var _visible_bits := PackedByteArray()
var _updates: int = 0
var _dirty: bool = true
# Scratch buffers reused by the per-update walks; each is cleared on entry and never escapes.
var _reach := {}
var _todo: Array[int] = []
var _box_clusters := {}
var _no_lights: Array[Dictionary] = []
var _light_nodes: Array[Light3D] = []
var _drawn_scratch: Array[AABB] = []   # reused by _gather_drawn so a camera jump allocates no list for it
var _lights_tree: SceneTree = null
# Sun instance id -> [signature of its receivers, their count, ReceiverGrid]; see _grid_for.
var _grids := {}


## The drawn chunks a sun shades, as a coarse occupancy grid: whether a swept box touches any is four reads and a mask.
## Conservative to a cell: a box near a receiver counts as touching it, so a shadow is never lost.
## Each (y, z) row of cells is a 16-bit mask of the occupied x cells, and a sparse table ORs power-of-two blocks of rows
## in y and z, so a query ORs four blocks and the build is one row write per receiver plus about 3000 ORs; the summed-volume
## table this replaced needed two three-axis prefix passes over 4913 cells (about 2 ms in script on the first camera jump).
class ReceiverGrid:
	const CELLS := 16
	const LEVELS := 5   # block heights 1, 2, 4, 8, 16
	const _LOG := [0, 0, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4]
	var bounds := AABB()
	var _table := PackedInt32Array()
	var _cell := Vector3.ONE

	func _init(receivers: Array[AABB]) -> void:
		if receivers.is_empty():
			return
		bounds = receivers[0]
		for r in receivers:
			bounds = bounds.merge(r)
		_cell = (bounds.size / CELLS).max(Vector3.ONE * 0.001)
		var t := PackedInt32Array()
		t.resize(LEVELS * LEVELS * CELLS * CELLS)
		for r in receivers:
			var a := _index(r.position, 0)
			var b := _index(r.end, 1)
			if b.x <= a.x:
				continue
			var mask := ((1 << (b.x - a.x)) - 1) << a.x
			for z in range(a.z, b.z):
				var row := z * CELLS
				for y in range(a.y, b.y):
					t[row + y] |= mask
		# Level (ky, kz) at (y, z) is the OR of 2^ky rows in y by 2^kz in z starting there; only entries that fit are written.
		for ky in LEVELS:
			var hy := 1 << ky
			if ky > 0:
				var half := hy >> 1
				var from := (ky - 1) * LEVELS * CELLS * CELLS
				var to := ky * LEVELS * CELLS * CELLS
				for z in CELLS:
					for y in range(0, CELLS - hy + 1):
						t[to + z * CELLS + y] = t[from + z * CELLS + y] | t[from + z * CELLS + y + half]
			for kz in range(1, LEVELS):
				var hz := 1 << kz
				var half_z := hz >> 1
				var base := (ky * LEVELS + kz) * CELLS * CELLS
				var below := (ky * LEVELS + kz - 1) * CELLS * CELLS
				for z in range(0, CELLS - hz + 1):
					for y in range(0, CELLS - (1 << ky) + 1):
						t[base + z * CELLS + y] = t[below + z * CELLS + y] | t[below + (z + half_z) * CELLS + y]
		_table = t

	## Cell coordinate of [param p], clamped; [param round_up] 1 gives the first cell past it (an exclusive end).
	func _index(p: Vector3, round_up: int) -> Vector3i:
		var f := (p - bounds.position) / _cell
		var v := Vector3i(floori(f.x), floori(f.y), floori(f.z)) + Vector3i.ONE * round_up
		return v.clamp(Vector3i.ZERO, Vector3i.ONE * (CELLS - 1 + round_up))

	## Whether [param box] overlaps a cell any receiver covers.
	func touches(box: AABB) -> bool:
		if _table.is_empty() or not box.intersects(bounds.grow(0.001)):
			return false
		var a := _index(box.position, 0)
		var b := _index(box.end, 1)
		if b.x <= a.x or b.y <= a.y or b.z <= a.z:
			return false
		var mask := ((1 << (b.x - a.x)) - 1) << a.x
		var ky: int = _LOG[b.y - a.y]
		var kz: int = _LOG[b.z - a.z]
		var base := (ky * LEVELS + kz) * CELLS * CELLS
		var y2 := b.y - (1 << ky)
		var z2 := b.z - (1 << kz)
		var rows := _table[base + a.z * CELLS + a.y] | _table[base + a.z * CELLS + y2] \
				| _table[base + z2 * CELLS + a.y] | _table[base + z2 * CELLS + y2]
		return (rows & mask) != 0


static func parse_mode(text: String) -> Mode:
	return MODE_NAMES.get(text.strip_edges().to_lower(), Mode.BOTH)


## Reads [param mesh]'s visibility and takes over [param drawn] (its [method GSMapBspMesh.build_node]
## tree, with [code]Props[/code] anywhere below it). Fails when the map has no visibility data;
## the world is then drawn as it was.
func setup(mesh: GSMapBspMesh, drawn: Node3D) -> GSResult:
	world = mesh
	root = drawn
	var info: Dictionary = mesh.manifest.get("vis", {})
	_clusters = int(info.get("clusters", 0))
	if _clusters > 0:
		_planes = mesh.vis_bytes("planes", 16).to_float32_array()
		_nodes = mesh.vis_bytes("nodes", 12).to_int32_array()
		_leaf_cluster = mesh.vis_bytes("leaf_cluster").to_int32_array()
		_cluster_area = mesh.vis_bytes("cluster_area").to_int32_array()
		_pvs_offsets = mesh.vis_bytes("pvs_offsets").to_int32_array()
		_pvs = mesh.vis_bytes("pvs", 1)
		_head = int(info.get("head", 0))
		if _pvs_offsets.size() != _clusters or _nodes.is_empty() or _leaf_cluster.is_empty():
			_clusters = 0
	_row_bytes = (_clusters + 7) / 8
	_portals = info.get("portals", [])
	for e: Dictionary in info.get("portal_entities", []):
		var t := str(e.get("target", ""))
		if not t.is_empty() and not bool(e.get("window", false)):
			if not _portal_targets.has(t):
				_portal_targets[t] = []
			(_portal_targets[t] as Array).append(int(e["key"]))
	_collect(drawn)
	_build_occluder(mesh)
	_apply_view_distance(mesh)
	_last_pos = Vector3.INF
	GSLog.debug(CHANNEL, "visibility set up", describe())
	if _clusters == 0 and _occluder == null:
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "the map has no visibility data", str(mesh.manifest.get("name", "")))
	_watch_lights()
	_apply_mode()
	return GSResult.success(self)


func set_mode(m: Mode) -> void:
	mode = m
	_apply_mode()


## Opens or closes one area portal by its key; a portal nobody set is open, so an unbound door never hides anything.
func set_portal_open(key: int, open: bool) -> void:
	_portal_open[key] = open
	_last_pos = Vector3.INF
	_dirty = true


## Opens or closes every area portal that follows the door named [param targetname].
func set_door_open(targetname: String, open: bool) -> void:
	for key: int in _portal_targets.get(targetname, []):
		_portal_open[key] = open
	_last_pos = Vector3.INF
	_dirty = true


## Follows every [GSAreaPortal] under [param under] (key or door set): their state is applied now and on each change. Returns how many were bound.
func bind_area_portals(under: Node) -> int:
	var n := 0
	for p in under.find_children("*", "GSAreaPortal", true, false):
		var portal := p as GSAreaPortal
		if portal.key < 0 and portal.door.is_empty():
			continue
		if not portal.toggled.is_connected(_on_area_portal.bind(portal)):
			portal.toggled.connect(_on_area_portal.bind(portal))
		_on_area_portal(portal.open, portal)
		n += 1
	return n


func _on_area_portal(open: bool, portal: GSAreaPortal) -> void:
	if portal.key >= 0:
		set_portal_open(portal.key, open)
	if not portal.door.is_empty():
		set_door_open(portal.door, open)


## Door names that have area portals following them, for a game to bind.
func portal_doors() -> PackedStringArray:
	return PackedStringArray(_portal_targets.keys())


func has_pvs() -> bool:
	return _clusters > 0


func _pvs_on() -> bool:
	return _clusters > 0 and (mode == Mode.PVS or mode == Mode.BOTH)


func _apply_mode() -> void:
	var occl := _occluder != null and (mode == Mode.OCCLUDERS or mode == Mode.BOTH)
	if _occluder != null:
		_occluder.visible = occl
		if is_inside_tree():
			if occl:
				_viewport_had_occlusion = get_viewport().use_occlusion_culling or _viewport_had_occlusion
				get_viewport().use_occlusion_culling = true
			elif not _viewport_had_occlusion:
				get_viewport().use_occlusion_culling = false
	if not _pvs_on():
		_show_all()
	_last_pos = Vector3.INF


func _collect(drawn: Node3D) -> void:
	_items.clear()
	_grids.clear()
	if _clusters == 0:
		return
	var stack: Array[Node] = [drawn]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_meta(&"vis_clusters"):
			_items.append({"node": n, "clusters": n.get_meta(&"vis_clusters"), "shown": true, "cast": false, "box": _aabb_under(n as Node3D, drawn) if n is Node3D else AABB()})
			continue
		if n.name == &"Props":
			for p in n.get_children():
				if p is Node3D:
					var box := _aabb_under(p as Node3D, drawn)
					if box.size != Vector3.ZERO:
						_items.append({"node": p, "clusters": clusters_in_box(box.grow(0.05)), "shown": true, "cast": false, "box": box})
			continue
		stack.append_array(n.get_children())
	for item in _items:
		if (item["clusters"] as PackedInt32Array).is_empty():
			item["clusters"] = PackedInt32Array([-1])   # touches no cluster: always drawn


## The bounds of every [VisualInstance3D] under [param n], in [param base]'s space.
static func _aabb_under(n: Node3D, base: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for v in n.find_children("*", "VisualInstance3D", true, false) + ([n] if n is VisualInstance3D else []):
		var xf := Transform3D.IDENTITY
		var at: Node = v
		while at != null and at != base:
			if at is Node3D:
				xf = (at as Node3D).transform * xf
			at = at.get_parent()
		var box: AABB = xf * (v as VisualInstance3D).get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


func _build_occluder(mesh: GSMapBspMesh) -> void:
	var verts := mesh.vis_bytes("occluder_vertices", 12).to_vector3_array()
	var index := mesh.vis_bytes("occluder_indices").to_int32_array()
	if verts.is_empty() or index.size() < 3:
		return
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, index)
	_occluder = OccluderInstance3D.new()
	_occluder.name = "Occluders"
	_occluder.occluder = occ
	root.add_child(_occluder)


func _apply_view_distance(mesh: GSMapBspMesh) -> void:
	var far := chunk_view_distance
	if far < 0.0:
		far = 0.0
		for f: Variant in mesh.environment_data().get("fog", []):
			if f is Dictionary and bool(f.get("enabled", false)) and float(f.get("far_z", -1)) > 0.0:
				far = maxf(far, float(f["far_z"]))
	if far <= 0.0:
		return
	for item in _items:
		var gi := item["node"] as GeometryInstance3D
		if gi != null and gi.visibility_range_end == 0.0:
			gi.visibility_range_end = far + 0.5 * gi.get_aabb().size.length()


func _process(_delta: float) -> void:
	if not _pvs_on() or (GSPlatform.is_headless() and not run_headless) or root == null:
		return
	var cam := _camera()
	if cam == null:
		return
	update_from(root.global_transform.affine_inverse() * cam.global_position)


func _camera() -> Camera3D:
	if camera_ref != null:
		return camera_ref.resolve_or_null(self, CHANNEL) as Camera3D
	return get_viewport().get_camera_3d()


## Shows and hides for a camera at [param local] (the drawn tree's space). Cheap when it has not moved.
func update_from(local: Vector3) -> void:
	if not _pvs_on() or local.distance_to(_last_pos) < move_step:
		return
	_last_pos = local
	var cams := clusters_in_box(AABB(local - Vector3.ONE * margin, Vector3.ONE * margin * 2.0))
	if cams == _camera_clusters and not _dirty:
		return
	_dirty = false
	_camera_clusters = cams
	_updates += 1
	if cams.is_empty():
		_show_all()
		clusters_changed.emit(cams)
		return
	_visible_bits = PackedByteArray()
	_visible_bits.resize(_row_bytes)
	for c in cams:
		_or_row(c)
	_mask_areas(cams)
	for item in _items:
		var show := false
		for c: int in item["clusters"]:
			if c < 0 or (_visible_bits[c >> 3] & (1 << (c & 7))) != 0:
				show = true
				break
		item["want"] = show
	_apply_shown(local)
	clusters_changed.emit(cams)


## Whether cluster [param c] is drawn for the camera's last position.
func is_cluster_visible(c: int) -> bool:
	if not _pvs_on() or _camera_clusters.is_empty() or c < 0 or c >= _clusters:
		return true
	return (_visible_bits[c >> 3] & (1 << (c & 7))) != 0


func _or_row(c: int) -> void:
	var at := _pvs_offsets[c]
	if at < 0 or at >= _pvs.size():
		_visible_bits.fill(255)
		return
	var o := 0
	while o < _row_bytes and at < _pvs.size():
		var b := _pvs[at]
		if b != 0:
			_visible_bits[o] |= b
			o += 1
			at += 1
		else:
			o += _pvs[at + 1] if at + 1 < _pvs.size() else _row_bytes
			at += 2


## Clears the clusters of areas the camera cannot reach through an open portal.
func _mask_areas(cams: PackedInt32Array) -> void:
	if _portals.is_empty() or not _portal_open.values().has(false):
		return
	var reach := _reach
	var todo := _todo
	reach.clear()
	todo.clear()
	for c in cams:
		var a := _cluster_area[c]
		if not reach.has(a):
			reach[a] = true
			todo.append(a)
	while not todo.is_empty():
		var a: int = todo.pop_back()
		for p: Array in _portals:
			if not bool(_portal_open.get(int(p[0]), true)):
				continue
			var other := -1
			if int(p[1]) == a:
				other = int(p[2])
			elif int(p[2]) == a:
				other = int(p[1])
			if other >= 0 and not reach.has(other):
				reach[other] = true
				todo.append(other)
	for c in _clusters:
		if not reach.has(_cluster_area[c]):
			_visible_bits[c >> 3] &= ~(1 << (c & 7))


## The leaf a point (the drawn tree's space) is in.
func leaf_at(p: Vector3) -> int:
	var node := _head
	while node >= 0:
		var pl := _nodes[node * 3] * 4
		var front := _planes[pl] * p.x + _planes[pl + 1] * p.y + _planes[pl + 2] * p.z - _planes[pl + 3] >= 0.0
		node = _nodes[node * 3 + (1 if front else 2)]
	return -1 - node


## Every cluster whose leaves a box (the drawn tree's space) touches.
func clusters_in_box(box: AABB) -> PackedInt32Array:
	if _clusters == 0:
		return PackedInt32Array()
	var out := _box_clusters
	out.clear()
	var c := box.get_center()
	var h := box.size * 0.5
	var stack := PackedInt32Array([_head])
	while not stack.is_empty():
		var node := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		if node < 0:
			var leaf := -1 - node
			if leaf < _leaf_cluster.size() and _leaf_cluster[leaf] >= 0:
				out[_leaf_cluster[leaf]] = true
			continue
		var pl := _nodes[node * 3] * 4
		var nx := _planes[pl]
		var ny := _planes[pl + 1]
		var nz := _planes[pl + 2]
		var d := nx * c.x + ny * c.y + nz * c.z - _planes[pl + 3]
		var r := absf(nx) * h.x + absf(ny) * h.y + absf(nz) * h.z
		if d > -r:
			stack.append(_nodes[node * 3 + 1])
		if d < r:
			stack.append(_nodes[node * 3 + 2])
	var keys := PackedInt32Array(out.keys())
	keys.sort()
	return keys


## Applies each item's "want" (drawn or not), then lets hidden ones keep casting shadows per [member shadows].
func _apply_shown(local: Vector3) -> void:
	var lights := _no_lights
	if shadows == Shadows.REACHING:
		lights = _active_lights(local)
	for item in _items:
		var show: bool = item["want"]
		var cast := false
		if not show:
			cast = shadows == Shadows.ALL or (shadows == Shadows.REACHING and _reached(item["box"], lights))
		_set_shown(item, show, cast)


## Shadow-casting lights, in the drawn tree's space, whose reach touches a drawn chunk: only those can put a hidden chunk's shadow on screen.
func _active_lights(local: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if root == null or not root.is_inside_tree():
		return out
	if _all_lights().is_empty():
		return out
	var inv := root.global_transform.affine_inverse()
	_gather_drawn()   # what the camera's clusters draw, once for every light
	for light in _all_lights():
		if not light.shadow_enabled or not light.is_visible_in_tree():
			continue
		var reach := INF
		var at := local
		if light is OmniLight3D:
			reach = (light as OmniLight3D).omni_range
			at = inv * light.global_position
		elif light is SpotLight3D:
			reach = (light as SpotLight3D).spot_range
			at = inv * light.global_position
		elif light is DirectionalLight3D:
			reach = (light as DirectionalLight3D).directional_shadow_max_distance
		var directional := light is DirectionalLight3D
		if not directional and not _reaches_drawn(at, reach):
			continue
		var entry := {"at": at, "reach": reach}
		if directional:
			var receivers: Array[AABB] = []   # only a sun needs them all, for its grid
			for box in _drawn_scratch:
				if at.distance_to(at.clamp(box.position, box.end)) <= reach:
					receivers.append(box)
			if receivers.is_empty():
				continue
			entry["dir"] = (inv.basis * -light.global_basis.z).normalized()
			entry["grid"] = ReceiverGrid.new(receivers)
		out.append(entry)
	return out


## Fills the scratch list with the boxes of the chunks and props the camera's clusters draw.
func _gather_drawn() -> void:
	_drawn_scratch.clear()
	for item in _items:
		if item["want"]:
			_drawn_scratch.append(item["box"])


## Whether a light at [param at] with [param reach] touches any drawn box: all a point or spot light needs.
func _reaches_drawn(at: Vector3, reach: float) -> bool:
	for box in _drawn_scratch:
		if at.distance_to(at.clamp(box.position, box.end)) <= reach:
			return true
	return false


## The [ReceiverGrid] of [param receivers], reused while the same chunks (by [param sig], their indices folded) receive the
## same sun: building one is a few thousand cell visits, and a camera that crosses a cluster border without changing which chunks are drawn asked for it again.
func _grid_for(light_id: int, sig: int, receivers: Array[AABB]) -> ReceiverGrid:
	var kept: Array = _grids.get(light_id, [])
	if kept.size() == 3 and kept[0] == sig and kept[1] == receivers.size():
		return kept[2]
	var grid := ReceiverGrid.new(receivers)
	_grids[light_id] = [sig, receivers.size(), grid]
	return grid


## Every Light3D in the tree, kept current by the tree's node_added and node_removed signals.
func _all_lights() -> Array[Light3D]:
	return _light_nodes


func _enter_tree() -> void:
	_watch_lights()
	if _occluder != null:
		_apply_mode()


## Off the tree (a world built before its root is added) there is nothing to watch yet; [method _enter_tree] calls it again.
func _watch_lights() -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	if tree == null or tree == _lights_tree:
		return
	_unwatch_lights()
	_lights_tree = tree
	tree.node_added.connect(_on_light_added)
	tree.node_removed.connect(_on_light_removed)
	_light_nodes.clear()
	for l in tree.root.find_children("*", "Light3D", true, false):
		_light_nodes.append(l as Light3D)


func _on_light_added(n: Node) -> void:
	if n is Light3D and not _light_nodes.has(n):
		_light_nodes.append(n as Light3D)


func _on_light_removed(n: Node) -> void:
	if n is Light3D:
		_light_nodes.erase(n as Light3D)


func _unwatch_lights() -> void:
	if _lights_tree != null and is_instance_valid(_lights_tree):
		_lights_tree.node_added.disconnect(_on_light_added)
		_lights_tree.node_removed.disconnect(_on_light_removed)
	_lights_tree = null
	_light_nodes.clear()


static func _box_distance(box: AABB, p: Vector3) -> float:
	var q := p.clamp(box.position, box.end)
	return p.distance_to(q)


func _reached(box: AABB, lights: Array[Dictionary]) -> bool:
	for l in lights:
		if l.has("dir"):
			# A sun's shadow falls along its direction from anywhere up-sun, however far: sweep the box and ask what it can land on.
			var swept := box.merge(AABB(box.position + (l["dir"] as Vector3) * SUN_SWEEP, box.size))
			if (l["grid"] as ReceiverGrid).touches(swept):
				return true
		elif _box_distance(box, l["at"]) <= float(l["reach"]):
			return true
	return false


func _set_shown(item: Dictionary, show: bool, cast: bool = false) -> void:
	if item["shown"] == show and item["cast"] == cast:
		return
	item["shown"] = show
	item["cast"] = cast
	var n: Node = item["node"]
	if not is_instance_valid(n):
		return
	if n.has_meta(&"shadow_proxy"):
		GSMapWorldShadow.mark(n, show or cast)   # a folded proxy stays on while any of its chunks is
		(n as Node3D).visible = show
		return
	if cast:
		(n as Node3D).visible = true
		for g in ([n] if n is GeometryInstance3D else n.find_children("*", "GeometryInstance3D", true, false)):
			if g.has_meta(&"shadow_cell"):
				(g as Node3D).visible = false   # its shadow is its cell's proxy, an item of its own
				continue
			if not g.has_meta(&"vis_cast"):
				g.set_meta(&"vis_cast", (g as GeometryInstance3D).cast_shadow)
			(g as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		return
	for g in ([n] if n is GeometryInstance3D else n.find_children("*", "GeometryInstance3D", true, false)):
		if g.has_meta(&"shadow_cell"):
			(g as Node3D).visible = true
		if g.has_meta(&"vis_cast"):
			(g as GeometryInstance3D).cast_shadow = g.get_meta(&"vis_cast")
			g.remove_meta(&"vis_cast")
	(n as Node3D).visible = show


func _show_all() -> void:
	for item in _items:
		_set_shown(item, true)
	_camera_clusters = PackedInt32Array()
	_dirty = true


## How many registered nodes are drawn now, of how many.
func shown_count() -> Vector2i:
	var on := 0
	for item in _items:
		if item["shown"]:
			on += 1
	return Vector2i(on, _items.size())


func describe() -> Dictionary:
	var shown := shown_count()
	return {"mode": MODE_NAMES.find_key(mode), "clusters": _clusters, "items": shown.y, "shown": shown.x,
			"camera_clusters": _camera_clusters.size(), "portals": _portals.size(),
			"occluder_triangles": (_occluder.occluder as ArrayOccluder3D).indices.size() / 3 if _occluder != null else 0,
			"updates": _updates}


func describe_lines() -> PackedStringArray:
	var d := describe()
	return PackedStringArray(["visibility %s: %d clusters, %d/%d drawn, camera in %d, %d portals, %d occluder triangles" % [
		d["mode"], d["clusters"], d["shown"], d["items"], d["camera_clusters"], d["portals"], d["occluder_triangles"]]])


func _exit_tree() -> void:
	_unwatch_lights()
	if _occluder != null and not _viewport_had_occlusion and get_viewport() != null:
		get_viewport().use_occlusion_culling = false
