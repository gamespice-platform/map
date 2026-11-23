class_name GSMapBoxBatch
extends RefCounted

## Draws a hand-built map's plain opaque boxes as a few meshes instead of one per box: [method build] folds the boxes of one material in one [constant CELL]-metre cell (x and z) into one [ArrayMesh], so draws fall to materials times cells and a far cell is still culled whole. Each folded box keeps its body, shapes and (hidden) mesh, so collision, picking and surveys see what they always saw.
## A candidate is a direct child of the parent that is a [StaticBody3D] holding one [MeshInstance3D] with a [BoxMesh] and only [CollisionShape3D]s besides, with an opaque material. A game vetoes more through [param skip], [code]func(body: Node3D, mesh: MeshInstance3D) -> bool[/code] (true leaves the box alone), e.g. a breakable or a door.
## [param coarse] (metres, default 0 = off) adds a second pass folding boxes alone in their cell into one coarse cell (say 256) per material; boxes already folded, see-through or vetoed never join. Skipped on a headless server ([param force] overrides, for a suite).

const GROUP := &"gs_map_box_batch"
## Set on a body whose mesh was folded, so a second [method build] does not fold it again.
const META_BATCHED := &"gs_map_box_batched"
## Metres a cell covers on x and z.
const CELL := 64.0
const NODE_NAME := "BoxBatch"


## Batches [param parent]'s box bodies. Returns `{boxes, nodes}`: boxes folded and meshes now drawing them. [param cell] is the cell edge in metres (zero or less puts everything of a material in one mesh).
## A cell holding one box of a material is left alone, unless [param coarse] is above [param cell] and another such box shares its coarse cell.
static func build(parent: Node3D, cell: float = CELL, skip: Callable = Callable(), force: bool = false, coarse: float = 0.0) -> Dictionary:
	if not force and DisplayServer.get_name() == "headless":
		return {"boxes": 0, "nodes": 0}
	var groups := {}
	for child in parent.get_children():
		if not child is StaticBody3D or child.has_meta(META_BATCHED):
			continue
		var mi := _plain_box_mesh(child)
		if mi == null or not mi.visible:
			continue
		var material := mi.get_active_material(0)
		if not _is_opaque(material):
			continue
		if skip.is_valid() and bool(skip.call(child, mi)):
			continue
		var at: Vector3 = (child as Node3D).position
		var cx := 0 if cell <= 0.0 else int(floorf(at.x / cell))
		var cz := 0 if cell <= 0.0 else int(floorf(at.z / cell))
		var key := [material, cx, cz, mi.cast_shadow, mi.layers]
		if not groups.has(key):
			groups[key] = {"material": material, "items": [], "shadow": mi.cast_shadow, "layers": mi.layers}
		groups[key]["items"].append([child, mi])
	if coarse > cell and cell > 0.0:
		_fold_singletons(groups, coarse)
	var holder := Node3D.new()
	holder.name = NODE_NAME
	holder.add_to_group(GROUP)
	var boxes := 0
	for key in groups:
		var g: Dictionary = groups[key]
		var items: Array = g["items"]
		if items.size() < 2:
			continue
		var node := _merge(items, g["material"])
		node.cast_shadow = g["shadow"]
		node.layers = g["layers"]
		holder.add_child(node)
		for it in items:
			(it[1] as MeshInstance3D).visible = false
			(it[0] as Node).set_meta(META_BATCHED, true)
		boxes += items.size()
	if holder.get_child_count() == 0:
		holder.free()
		return {"boxes": 0, "nodes": 0}
	parent.add_child(holder)
	return {"boxes": boxes, "nodes": holder.get_child_count()}


## Moves the boxes that are alone in their fine cell into [param coarse]-metre groups.
static func _fold_singletons(groups: Dictionary, coarse: float) -> void:
	var wide := {}
	for key in groups.keys():
		var g: Dictionary = groups[key]
		if (g["items"] as Array).size() != 1:
			continue
		var item: Array = g["items"][0]
		var at: Vector3 = (item[0] as Node3D).position
		var wkey := [g["material"], int(floorf(at.x / coarse)), int(floorf(at.z / coarse)), g["shadow"], g["layers"], "coarse"]
		if not wide.has(wkey):
			wide[wkey] = {"material": g["material"], "items": [], "shadow": g["shadow"], "layers": g["layers"]}
		wide[wkey]["items"].append(item)
		groups.erase(key)
	for wkey in wide:
		groups[wkey] = wide[wkey]


## Shows the folded boxes' own meshes again and frees the merged ones.
static func undo(parent: Node3D) -> int:
	var shown := 0
	for child in parent.get_children():
		if child is StaticBody3D and child.has_meta(META_BATCHED):
			for part in child.get_children():
				if part is MeshInstance3D:
					(part as MeshInstance3D).visible = true
			child.remove_meta(META_BATCHED)
			shown += 1
	for holder in parent.get_children():
		if holder.is_in_group(GROUP):
			parent.remove_child(holder)
			holder.free()
	return shown


static func _is_opaque(material: Material) -> bool:
	if material is BaseMaterial3D:
		var m := material as BaseMaterial3D
		return m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and m.albedo_color.a >= 0.999
	return false


static func _plain_box_mesh(body: Node) -> MeshInstance3D:
	var found: MeshInstance3D = null
	for part in body.get_children():
		if part is MeshInstance3D and (part as MeshInstance3D).mesh is BoxMesh:
			if found != null:
				return null
			found = part
		elif not (part is CollisionShape3D):
			return null
	return found


static func _merge(items: Array, material: Material) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for it in items:
		var body: Node3D = it[0]
		var mi: MeshInstance3D = it[1]
		var arrays: Array = (mi.mesh as BoxMesh).get_mesh_arrays()
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var t := body.transform * mi.transform
		var normal_basis := t.basis.inverse().transposed()
		var base := verts.size()
		for i in v.size():
			verts.append(t * v[i])
			normals.append((normal_basis * n[i]).normalized())
		uvs.append_array(uv)
		for i in idx:
			indices.append(base + i)
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	mesh.surface_set_material(0, material)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	return node
