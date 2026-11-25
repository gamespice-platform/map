extends "tests_terrain.gd"

## The prop batching and chunk merging sections of the bsp mesh suite.


func _box_mesh(size: Vector3, mat: Material) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	out.surface_set_material(0, mat)
	return out


func _prop(parent: Node3D, mesh: Mesh, xf: Transform3D) -> Node3D:
	var p := Node3D.new()
	p.transform = xf
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	p.add_child(mi)
	parent.add_child(p)
	return p


## Every drawn triangle under [param root], world space, per material: "material|a|b|c" with the corners in millimetres and
## rotated to start at the smallest, so the side the face is drawn from is part of the key.
func _triangles(root: Node3D) -> Array:
	var out := []
	var drawn := []   # [mesh, override, transform]
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		drawn.append([(n as MeshInstance3D).mesh, (n as MeshInstance3D).material_override, (n as Node3D).global_transform])
	for n: Node in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mm := (n as MultiMeshInstance3D).multimesh
		var placed: Array = n.get_meta(&"test_placed")   # the headless server keeps no instance transforms
		for xf: Transform3D in placed:
			drawn.append([mm.mesh, (n as MultiMeshInstance3D).material_override, (n as Node3D).global_transform * xf])
	for d: Array in drawn:
		var mesh: Mesh = d[0]
		var xf: Transform3D = d[2]
		for s in mesh.get_surface_count():
			var a := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(v.size()))
			var mat: Material = d[1] if d[1] else mesh.surface_get_material(s)
			for i in range(0, idx.size(), 3):
				var c := [xf * v[idx[i]], xf * v[idx[i + 1]], xf * v[idx[i + 2]]].map(func(p: Vector3) -> String: return str(Vector3i((p * 1000.0).round())))
				if xf.basis.determinant() < 0.0:
					c.reverse()   # Godot draws a mirrored instance's faces turned back the right way out
				var lo := c.find(c.min())
				out.append("%s|%s|%s|%s" % [mat.get_instance_id() if mat else 0, c[lo], c[(lo + 1) % 3], c[(lo + 2) % 3]])
	out.sort()
	return out


func _test_prop_batch() -> void:
	_section("small static props bake into one mesh per material per cell, drawing the same triangles")
	var red := StandardMaterial3D.new()
	var blue := StandardMaterial3D.new()
	var small := _box_mesh(Vector3(1, 2, 0.5), red)
	var other := _box_mesh(Vector3(0.3, 0.3, 0.3), blue)
	var sphere := SphereMesh.new()
	sphere.radial_segments = 64
	sphere.rings = 32
	var big := ArrayMesh.new()
	big.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	_prop(props, small, Transform3D(Basis.IDENTITY, Vector3(1, 0, 1)))
	_prop(props, small, Transform3D(Basis(Vector3.UP, 0.7).scaled(Vector3(1.5, 1, 1)), Vector3(3, 1, 2)))
	_prop(props, small, Transform3D(Basis.IDENTITY.scaled(Vector3(-1, 1, 1)), Vector3(5, 0, 4)))   # mirrored
	_prop(props, other, Transform3D(Basis(Vector3.RIGHT, 1.1), Vector3(2, 3, 6)))
	var mixed := _prop(props, big, Transform3D(Basis.IDENTITY, Vector3(8, 0, 8)))
	var part := MeshInstance3D.new()
	part.mesh = other
	part.position = Vector3(0, 2, 0)
	mixed.add_child(part)
	_prop(props, big, Transform3D(Basis(Vector3.UP, 0.3), Vector3(300, 0, 20)))
	_prop(props, big, Transform3D(Basis.IDENTITY.scaled(Vector3(2, 2, 2)), Vector3(304, 0, 20)))
	var copies := props.get_children().slice(-2).map(func(c: Node) -> Dictionary: return {"mi": c.get_child(0), "xf": (c as Node3D).transform})
	var expect_placed := GSMapPropBatch.instance_transforms(copies, (copies[0]["xf"] * (copies[0]["mi"] as MeshInstance3D).get_aabb()).merge(
			copies[1]["xf"] * (copies[1]["mi"] as MeshInstance3D).get_aabb()).get_center())
	var far := _prop(props, small, Transform3D(Basis.IDENTITY, Vector3(200, 0, 0)))
	(far.get_child(0) as MeshInstance3D).visibility_range_end = 40.0
	var scripted := _prop(props, small, Transform3D(Basis.IDENTITY, Vector3(2, 0, 2)))
	scripted.add_to_group(&"breakable")
	var before := _triangles(props)
	var b := GSMapPropBatch.new()
	b.max_tris = 1000
	var n := b.batch(props)
	for mmi: Node in props.find_children("*", "MultiMeshInstance3D", true, false):
		mmi.set_meta(&"test_placed", expect_placed)
	var after := _triangles(props)
	var off := range(mini(before.size(), after.size())).filter(func(i: int) -> bool: return before[i] != after[i])
	_check(before.size() == after.size() and off.is_empty(), "the same triangles, materials and windings are drawn (%d before, %d after, %d differ: %s)" % [
			before.size(), after.size(), off.size(), [before[off[0]], after[off[0]]] if not off.is_empty() else ""])
	_check(n == 2 and b.chunks == 2, "one chunk for the near cell and one for the far, faded prop: %d" % n)
	_check(b.batched_meshes == 6 and b.batched_props == 6, "six small meshes of six props baked: %d meshes, %d props" % [b.batched_meshes, b.batched_props])
	var near := props.get_children().filter(func(c: Node) -> bool: return c is MeshInstance3D and (c as MeshInstance3D).visibility_range_end == 0.0)
	_check(near.size() == 1 and (near[0] as MeshInstance3D).mesh.get_surface_count() == 2, "the near chunk is one surface per material")
	var faded := props.get_children().filter(func(c: Node) -> bool: return c is MeshInstance3D and (c as MeshInstance3D).visibility_range_end > 0.0)
	_check(faded.size() == 1 and (faded[0] as MeshInstance3D).visibility_range_end >= 40.0, "a faded prop's chunk fades no earlier")
	_check(is_instance_valid(scripted) and scripted.get_parent() == props and scripted.get_child_count() == 1, "a prop in a group keeps its own node")
	_check(is_instance_valid(mixed) and mixed.get_child_count() == 1 and (mixed.get_child(0) as MeshInstance3D).mesh == big,
			"a prop's large mesh keeps its node while its small part is baked")
	_check(b.multimeshes == 1 and b.instanced_meshes == 2, "two copies of a large mesh in one cell are one multimesh: %d of %d" % [b.multimeshes, b.instanced_meshes])
	var none := GSMapPropBatch.new()
	none.max_tris = 0
	_check(none.batch(props) == 0, "a max_tris of 0 bakes nothing")
	props.free()
	_done()


## A door model carries an AnimationPlayer nobody plays: its mesh bakes. One that autoplays keeps its prop whole.
func _test_prop_batch_animated() -> void:
	_section("a prop with an idle AnimationPlayer is baked, one with an autoplaying player is not")
	var small := _box_mesh(Vector3(1, 2, 0.5), StandardMaterial3D.new())
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	var idle := _prop(props, small, Transform3D(Basis.IDENTITY, Vector3(1, 0, 1)))
	idle.add_child(AnimationPlayer.new())
	var playing := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = small
	playing.add_child(mi)
	playing.position = Vector3(3, 0, 1)
	var player := AnimationPlayer.new()
	var lib := AnimationLibrary.new()
	lib.add_animation(&"open", Animation.new())
	player.add_animation_library(&"", lib)
	player.autoplay = &"open"
	playing.add_child(player)
	props.add_child(playing)
	var b := GSMapPropBatch.new()
	b.max_tris = 1000
	b.instance_cell = 0.0
	var n := b.batch(props)
	_check(n == 1 and b.batched_props == 1, "one chunk, from the prop with the idle player: %d chunks, %d props" % [n, b.batched_props])
	_check(idle.find_children("*", "MeshInstance3D", true, false).is_empty(), "the idle prop's mesh is in the chunk")
	_check(playing.find_children("*", "MeshInstance3D", true, false).size() == 1, "the autoplaying prop keeps its mesh")
	props.free()
	_done()


func _test_prop_batch_primitive() -> void:
	_section("loose primitive boxes (a stand-in block) are baked: one chunk, the same triangles and bounds")
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	var mat := StandardMaterial3D.new()
	for i in 3:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1 + i, 2, 1)
		box.material = mat
		mi.mesh = box
		mi.position = Vector3(i * 4, 1, 0)
		mi.rotation_degrees.y = 30.0 * i
		props.add_child(mi)
	var b := GSMapPropBatch.new()
	b.max_tris = 1000
	b.instance_cell = 0.0
	var n := b.batch(props)
	_check(n == 1 and b.batched_meshes == 3, "one chunk from three boxes: %d chunks, %d meshes" % [n, b.batched_meshes])
	var chunk := props.get_child(0) as MeshInstance3D
	_check(chunk.mesh.get_surface_count() == 1 and chunk.mesh.surface_get_material(0) == mat, "one surface with the boxes' material")
	_check(chunk.mesh.surface_get_array_index_len(0) == 3 * 36, "the boxes' 36 indices each: %d" % chunk.mesh.surface_get_array_index_len(0))
	_check(chunk.mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_NORMAL != 0, "normals kept")
	props.free()
	_done()


func _test_chunk_merge(world: GSMapBspMesh) -> void:
	_section("chunk merging: a small map keeps its cells, a merged one draws the same triangles in fewer chunks")
	_check(world.chunk_merge == 0 and world.auto_merge(0) == 1, "by default the fixture's two chunks are left alone")
	var whole := world.build_node(func(_r: Dictionary) -> Material: return null)
	add_child(whole)
	var cells := (whole.get_node("world") as Node3D).get_children().filter(func(c: Node) -> bool: return not str(c.name).begins_with("shadow_"))

	world.chunk_target = 1
	var n := world.auto_merge(0)
	var merged := world.build_node(func(_r: Dictionary) -> Material: return null)
	add_child(merged)
	var one := (merged.get_node("world") as Node3D).get_children().filter(func(c: Node) -> bool: return not str(c.name).begins_with("shadow_"))
	_check(n > 1 and one.size() == 1 and cells.size() == 2, "a target of one merges the cells into one chunk: n=%d, %d -> %d" % [n, cells.size(), one.size()])
	var shadows := (merged.get_node("world") as Node3D).get_children().filter(func(c: Node) -> bool: return str(c.name).begins_with("shadow_"))
	_check(_tri_count(one) == _tri_count(cells), "the merged chunk draws every triangle: %d vs %d" % [_tri_count(one), _tri_count(cells)])
	_check(shadows.size() <= 1, "one shadow proxy for the merged chunk: %d" % shadows.size())
	world.chunk_target = 512
	whole.free()
	merged.free()
	_done()


func _tri_count(nodes: Array) -> int:
	var t := 0
	for n: Node in nodes:
		var m := (n as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var a := m.surface_get_arrays(s)
			t += ((a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if a[Mesh.ARRAY_INDEX] != null else (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return t


## The world-space triangles of every mesh under [param root] that casts a sun shadow, corners in millimetres, rotated to start at the smallest.
func _shadow_triangles(root: Node3D) -> Array:
	var out := []
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			continue
		var xf := mi.global_transform
		for s in mi.mesh.get_surface_count():
			var a := mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(v.size()))
			for i in range(0, idx.size(), 3):
				var c := [xf * v[idx[i]], xf * v[idx[i + 1]], xf * v[idx[i + 2]]].map(func(p: Vector3) -> String: return str(Vector3i((p * 1000.0).round())))
				if xf.basis.determinant() < 0.0:
					c.reverse()
				var lo := c.find(c.min())
				out.append("%s|%s|%s" % [c[lo], c[(lo + 1) % 3], c[(lo + 2) % 3]])
	out.sort()
	return out


func _test_prop_shadow() -> void:
	_section("prop shadows fold into one shadows-only mesh per cell, casting the same triangles")
	var solid := StandardMaterial3D.new()
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var leaves := StandardMaterial3D.new()
	leaves.cull_mode = BaseMaterial3D.CULL_DISABLED
	var crate := _box_mesh(Vector3(1, 1, 1), solid)
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	var a := _prop(props, crate, Transform3D(Basis.IDENTITY, Vector3(1, 0, 1)))
	_prop(props, crate, Transform3D(Basis(Vector3.UP, 0.6), Vector3(4, 0, 2)))
	var mirrored := _prop(props, crate, Transform3D(Basis.IDENTITY.scaled(Vector3(-1, 1, 1)), Vector3(6, 0, 3)))
	var see := _prop(props, _box_mesh(Vector3(1, 1, 1), glass), Transform3D(Basis.IDENTITY, Vector3(2, 0, 5)))
	var bush := _prop(props, _box_mesh(Vector3(2, 1, 2), leaves), Transform3D(Basis.IDENTITY, Vector3(3, 0, 7)))
	var far := _prop(props, crate, Transform3D(Basis.IDENTITY, Vector3(100, 0, 0)))
	var loose := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.5, 0.5)
	loose.mesh = box
	loose.position = Vector3(2, 1, 2)
	props.add_child(loose)
	var scripted := _prop(props, crate, Transform3D(Basis.IDENTITY, Vector3(5, 0, 5)))
	scripted.add_to_group(&"breakable")
	var before := _shadow_triangles(props)
	var s := GSMapPropShadow.new()
	var n := s.fold(props)
	var after := _shadow_triangles(props)
	var off := range(mini(before.size(), after.size())).filter(func(i: int) -> bool: return before[i] != after[i])
	_check(before.size() == after.size() and off.is_empty(), "the same shadow triangles and windings are cast (%d before, %d after, %d differ)" % [before.size(), after.size(), off.size()])
	_check(n == 3 and s.proxies == 3, "a one-sided and a two-sided proxy near, one far: %d" % n)
	_check(s.folded_meshes == 6, "six meshes folded (three crates, the bush, the far crate, the loose box): %d" % s.folded_meshes)
	var cells := props.get_children().filter(func(c: Node) -> bool: return c.has_meta(&"gs_map_shadow_cell"))
	_check(cells.size() == 3 and cells.all(func(c: Node) -> bool: return (c as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY),
			"the proxies are shadows only: %d" % cells.size())
	var two := cells.filter(func(c: Node) -> bool: return str(c.name).ends_with("_2"))
	_check(two.size() == 1 and (two[0] as MeshInstance3D).material_override != null \
			and ((two[0] as MeshInstance3D).material_override as BaseMaterial3D).cull_mode == BaseMaterial3D.CULL_DISABLED, "the two-sided bush casts from both sides")
	for p: Node3D in [a, mirrored, far]:
		var mi := p.get_child(0) as MeshInstance3D
		_check(mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and mi.get_meta(&"shadow_cell", null) is MeshInstance3D, "%s casts through its cell" % p.name)
	_check((see.get_child(0) as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON and not (see.get_child(0) as Node).has_meta(&"shadow_cell"),
			"a translucent prop keeps its own shadow")
	_check((scripted.get_child(0) as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "a prop in a group keeps its own shadow")
	_check((bush.get_child(0) as MeshInstance3D).get_meta(&"shadow_cell", null) == two[0], "the bush is in the two-sided cell")
	var none := GSMapPropShadow.new()
	none.max_tris = 0
	_check(none.fold(props) == 0, "a max_tris of 0 folds nothing")
	props.free()
	# LOD levels: a scaled member with two, one with one, one with none; level k at the largest scaled edge, a short member at its coarsest.
	var a1 := PackedInt32Array([0, 1, 2])
	var a2 := PackedInt32Array([0, 2, 1])
	var levels := GSMapPropShadow._levels([
		[0, PackedInt32Array([0, 1, 2, 0, 2, 1]), [[1.0, a1], [2.0, a2]], 2.0, false],
		[10, PackedInt32Array([0, 1, 2]), [[3.0, PackedInt32Array([1, 2, 0])]], 1.0, false],
		[20, PackedInt32Array([0, 1, 2]), [], 1.0, true]])
	_check(levels.keys() == [3.0, 4.0], "proxy LOD edges are the largest scaled member edges: %s" % [levels.keys()])
	_check(levels.get(3.0, PackedInt32Array()) == PackedInt32Array([0, 1, 2, 11, 12, 10, 20, 22, 21]), "level 0 joins each member's first level, the plain one whole and mirrored")
	_check(levels.get(4.0, PackedInt32Array()) == PackedInt32Array([0, 2, 1, 11, 12, 10, 20, 22, 21]), "level 1 keeps a one-level member at its coarsest")
	_check(GSMapPropShadow._levels([[0, a1, [], 1.0, false]]).is_empty(), "members without LODs give a proxy without LODs")
	_done()


func _test_world_shadow(world: GSMapBspMesh) -> void:
	_section("world chunk shadows fold into one shadows-only mesh per cell, casting the same triangles")
	var node := world.build_node(func(_r: Dictionary) -> Material: return null)
	add_child(node)
	var w := node.get_node("world") as Node3D
	var chunks := w.get_children().filter(func(c: Node) -> bool: return c.has_meta(&"shadow_proxy"))
	var before := _shadow_triangles(w)
	var apart := GSMapWorldShadow.new()
	apart.cell = 0.001
	_check(apart.fold(w) == 0 and _shadow_triangles(w) == before, "a cell smaller than a chunk folds nothing")
	var folder := GSMapWorldShadow.new()
	folder.cell = 100000.0
	var made := folder.fold(w)
	var proxies := w.get_children().filter(func(c: Node) -> bool: return str(c.name).begins_with("shadow_"))
	_check(chunks.size() == 2 and made == 1 and folder.folded == 2 and proxies.size() == 1, "two chunks, one fold: %d chunks, %d made, %d proxies" % [chunks.size(), made, proxies.size()])
	var fold := proxies[0] as MeshInstance3D
	_check(fold.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY and chunks.all(func(c: Node) -> bool: return c.get_meta(&"shadow_proxy") == fold)
			and (fold.get_meta(&"shadow_members") as Array).size() == 2, "the fold is shadows-only and both chunks point at it")
	_check(_shadow_triangles(w) == before, "it casts exactly the triangles the two proxies did: %d" % before.size())
	GSMapWorldShadow.mark(chunks[0], false)
	var one_on := fold.visible
	GSMapWorldShadow.mark(chunks[1], false)
	_check(one_on and not fold.visible, "it stays on while one chunk is, off when neither is")
	node.free()
	_done()
