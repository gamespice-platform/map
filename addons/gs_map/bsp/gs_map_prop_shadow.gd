class_name GSMapPropShadow
extends RefCounted
## Draws the sun shadows of a world's static props from one position-only, shadows-only mesh per [member cell] instead of one shadow draw per prop mesh per cascade (an industrial map: 78 visible prop draws, 319 prop shadow draws).
## [method fold] copies the opaque meshes of every plain prop under a world's [code]Props[/code] node ([method GSMapPropBatch._plain]) into per-cell proxies, turns their own shadow off and marks each with meta [code]shadow_cell[/code] (the proxy).
## The proxies are direct children of [code]Props[/code], so [GSMapVisibility] culls them as it does a prop, and keeps a hidden marked mesh from casting twice. A translucent, alpha-tested, billboard or shader-drawn mesh keeps its own shadow, as does one over [member max_tris]. A member's LOD levels are carried into its proxy ([method _levels]).

const CHANNEL := "gs_map.prop_shadow"

## The edge of a shadow cell, metres. Smaller keeps a proxy's cascade and fade culling closer to its members'; larger folds more meshes into one draw.
## 16 on an industrial map: 585 draws and 1.59M primitives a frame against 704 and 1.21M unfolded; 32 drew 566 but 2.41M.
var cell: float = 16.0
## Most triangles a mesh may have to be folded: a larger one keeps its own shadow and LOD levels. 0 folds none.
var max_tris: int = 20000

## Meshes the last [method fold] took the shadow of, and the proxies drawing them.
var folded_meshes: int = 0
var proxies: int = 0

static var _double_sided: StandardMaterial3D = null


## Folds the shadows of the plain props under [param props] into per-cell proxies; returns the number of proxies made.
func fold(props: Node3D) -> int:
	folded_meshes = 0
	proxies = 0
	if max_tris <= 0:
		return 0
	var tris_of := {}
	var arrays_of := {}
	var cells := {}   # key -> [{mi, xf}]
	for c in props.get_children():
		if not GSMapPropBatch._plain(c):
			continue
		var parts: Array[Dictionary] = []
		GSMapPropBatch._collect(c as Node3D, Transform3D.IDENTITY, (c as Node3D).transform, parts)
		for p in parts:
			var mi: MeshInstance3D = p["mi"]
			var sides := _sides(mi)
			if sides == 0 or not GSMapPropBatch._small(mi.mesh, tris_of, max_tris):
				continue
			var at := (p["xf"] as Transform3D) * mi.get_aabb().get_center()
			var key := [Vector3i((at / cell).floor()), sides, mi.layers, mi.visibility_range_fade_mode, GSMapPropBatch._fade_bucket(mi.visibility_range_end)]
			if not cells.has(key):
				cells[key] = []
			(cells[key] as Array).append(p)
	for key: Array in cells:
		var node := _proxy(cells[key], int(key[1]) == 2, arrays_of)
		if node == null:
			continue
		props.add_child(node)
		for p: Dictionary in cells[key]:
			var mi: MeshInstance3D = p["mi"]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.set_meta(&"shadow_cell", node)
			folded_meshes += 1
		proxies += 1
	GSLog.debug(CHANNEL, "prop shadows folded", {"meshes": folded_meshes, "proxies": proxies})
	return proxies


## 1 when [param mi]'s shadow is its front faces only, 2 when both sides cast, 0 when it cannot be folded: no shadow,
## faded by hand, or a surface whose shadow is not its plain shape (translucent, alpha-tested, billboard, grown, shader-drawn, front-culled).
static func _sides(mi: MeshInstance3D) -> int:
	var cast := mi.cast_shadow
	if cast != GeometryInstance3D.SHADOW_CASTING_SETTING_ON and cast != GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED:
		return 0
	if mi.transparency > 0.0 or mi.visibility_range_begin > 0.0:
		return 0
	var both := cast == GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	for s in mi.mesh.get_surface_count():
		var m: Material = GSMapPropBatch._material(mi, s)
		if m == null:
			continue
		if not m is BaseMaterial3D or m.next_pass != null:
			return 0
		var b := m as BaseMaterial3D
		if b.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or b.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED \
				or b.grow or b.use_point_size or b.cull_mode == BaseMaterial3D.CULL_FRONT:
			return 0
		both = both or b.cull_mode == BaseMaterial3D.CULL_DISABLED
	return 2 if both else 1


## One shadows-only mesh of [param list]'s members (each [code]{mi, xf}[/code]) in the Props node's space, centred on their bounds; null when they hold no triangles.
func _proxy(list: Array, double_sided: bool, arrays_of: Dictionary) -> MeshInstance3D:
	var box := AABB()
	for i in list.size():
		var p: Dictionary = list[i]
		var b: AABB = (p["xf"] as Transform3D) * (p["mi"] as MeshInstance3D).get_aabb()
		box = b if i == 0 else box.merge(b)
	var centre := box.get_center()
	var verts := PackedVector3Array()
	var index := PackedInt32Array()
	var parts := []   # [base, full, lods, scale, flip]
	for p: Dictionary in list:
		var mi: MeshInstance3D = p["mi"]
		var xf := Transform3D(Basis.IDENTITY, -centre) * (p["xf"] as Transform3D)
		var scale := xf.basis.get_scale().abs()
		for got: Array in _positions(mi.mesh, arrays_of):
			parts.append([verts.size(), got[1], got[2], maxf(scale.x, maxf(scale.y, scale.z)), xf.basis.determinant() < 0.0])
			verts.append_array(xf * (got[0] as PackedVector3Array))
	for part: Array in parts:
		_append(index, part[1], part[0], part[4])
	if index.is_empty():
		return null
	var lod_of := _levels(parts)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = index
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lod_of)
	var node := MeshInstance3D.new()
	var first: MeshInstance3D = list[0]["mi"]
	var c := Vector3i((centre / cell).floor())
	node.name = "shadow_cell_%d_%d_%d%s" % [c.x, c.y, c.z, "_2" if double_sided else ""]
	node.mesh = mesh
	node.position = centre
	node.layers = first.layers
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if double_sided:
		node.material_override = _two_sided()
	node.set_meta(&"gs_map_shadow_cell", true)
	node.visibility_range_fade_mode = first.visibility_range_fade_mode
	GSMapPropBatch._fade_like(node, list, centre)
	return node


## The proxy's LOD levels ([code]{edge length: triangle indices}[/code]) from [param parts], each [code][first vertex, triangle indices, LOD levels, scale, mirrored][/code]:
## level k is level k of every member (its coarsest when it has fewer, its full mesh when it has none) at the largest scaled member edge, so the proxy,
## never farther from the camera than a member, keeps at least the detail each member's own shadow had.
static func _levels(parts: Array) -> Dictionary:
	var count := 0
	for part: Array in parts:
		count = maxi(count, (part[2] as Array).size())
	var out := {}
	var last := 0.0
	for k in count:
		var edge := 0.0
		var tri := PackedInt32Array()
		for part: Array in parts:
			var lods: Array = part[2]
			if lods.is_empty():
				_append(tri, part[1], part[0], part[4])
				continue
			var lod: Array = lods[mini(k, lods.size() - 1)]
			edge = maxf(edge, float(lod[0]) * float(part[3]))
			_append(tri, lod[1], part[0], part[4])
		last = maxf(edge, last * 1.0001 + 0.000001)
		out[last] = tri
	return out


## [param mesh]'s surfaces as [code][positions, triangle indices, LOD levels][/code], read once per mesh; each LOD level is [code][edge length, triangle indices][/code], finest first.
static func _positions(mesh: Mesh, arrays_of: Dictionary) -> Array:
	if not arrays_of.has(mesh):
		var out := []
		for s in mesh.get_surface_count():
			var a := GSMapPropBatch._arrays(mesh, s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var idx: Variant = a[Mesh.ARRAY_INDEX]
			var tri := PackedInt32Array()
			if idx == null or (idx as PackedInt32Array).is_empty():
				tri.resize(v.size() - v.size() % 3)
				for i in tri.size():
					tri[i] = i
			else:
				tri = idx
			out.append([v, tri, _lods(mesh, s, v.size()) if idx != null else []])
		arrays_of[mesh] = out
	return arrays_of[mesh]


## The LOD levels of surface [param s] of an [ArrayMesh] (an imported model's), decoded from the rendering server's index data.
static func _lods(mesh: Mesh, s: int, vertex_count: int) -> Array:
	if not mesh is ArrayMesh:
		return []
	var surface: Dictionary = RenderingServer.mesh_get_surface(mesh.get_rid(), s)
	var out := []
	for lod: Dictionary in surface.get("lods", []):
		var data: PackedByteArray = lod["index_data"]
		var tri := PackedInt32Array()
		if vertex_count <= 65536:
			tri.resize(data.size() / 2)
			for i in tri.size():
				tri[i] = data.decode_u16(i * 2)
		else:
			tri = data.to_int32_array()
		tri.resize(tri.size() - tri.size() % 3)
		out.append([float(lod["edge_length"]), tri])
	return out


## Adds [param tri] to [param into], shifted by [param base] and turned over when [param flip].
static func _append(into: PackedInt32Array, tri: PackedInt32Array, base: int, flip: bool) -> void:
	var idx := GSMapPropBatch._flipped(tri) if flip else tri
	var at := into.size()
	into.resize(at + idx.size())
	for i in idx.size():
		into[at + i] = base + idx[i]


static func _two_sided() -> StandardMaterial3D:
	if _double_sided == null:
		_double_sided = StandardMaterial3D.new()
		_double_sided.cull_mode = BaseMaterial3D.CULL_DISABLED
		_double_sided.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _double_sided
