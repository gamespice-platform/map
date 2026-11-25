# Add culling to your level in 5 minutes

For a level you built in the editor, not a converted BSP map (those use [visibility.md](visibility.md)). Nothing here is on by default and nothing needs a script in your game.

## What Godot already does, and what this adds

| Need | Godot 4.7 | GameSpice Map |
| --- | --- | --- |
| Hide what is behind a wall | `OccluderInstance3D` with a `BoxOccluder3D`, `QuadOccluder3D`, `PolygonOccluder3D` or a baked scene occluder; turn on `Viewport.use_occlusion_culling` (Project Settings, Rendering, Occlusion Culling) | Nothing; use it |
| Hide what is far | `GeometryInstance3D.visibility_range_end` and fade; HLOD by pairing two ranges | Nothing; use it |
| Skip a node off-screen | `VisibleOnScreenNotifier3D` (frustum only, ignores walls) | Nothing |
| Rooms and portals | Removed. Godot 4.0 to 4.3 had `RoomManager`, `Room` and `Portal`; none exists in 4.7 (`ClassDB.class_exists("RoomManager")` is false) | No room graph either: occluders do the job for static walls, and a room node would only duplicate them |
| Bake occluders | `OccluderInstance3D` has its own bake, which merges all meshes into one simplified mesh: slow and fuzzy on a level full of props | `GSOccluderBaker`: only large flat faces, as quads, reproducible, headless |
| A door that opens | An occluder cannot change shape; you would toggle one by hand | `GSAreaPortal`: a doorway box that occludes while closed |

An honest summary: Godot does the culling. These two classes feed it the occluders a level author would otherwise place by hand, and keep a door's occluder in step with the door.

## 1. Bake occluders from the walls

In the editor, open your level scene (a `Node3D` root) and choose Project, Tools, **Bake occluders for the edited scene**; save. Or headless, for CI and scripts, from the gs-map checkout or with the script's path:

```bash
godot --headless --path . --import
godot --headless --path . -s tools/bake_occluders.gd -- res://levels/arena.tscn [--out=res://levels/arena_baked.tscn] [--dry]
```

It prints `N meshes, N large faces, N quads` and writes one `OccluderInstance3D` named `BakedOccluders` into the scene. Baking again replaces it.

What becomes a quad: a group of one mesh's triangles on one plane that is at least 6 m² (`min_area`), at least 1.5 m on its short side (`min_side`) and at least 85% filled (`min_fill`). A wall with a doorway cut into one mesh fails the fill test and is skipped, because a quad over the hole would hide the next room; build it as several boxes instead, or put a `GSAreaPortal` in the hole. Every quad is pulled in 4 cm from its edges so it never hides the face it lies on. At most 256 are kept, the largest first.

Never baked: hidden nodes, translucent meshes (`transparency`, or a material with alpha), shadow-only meshes, and anything in the group `gs_no_occluder`. Set the group on glass, foliage planes and anything that moves or can be destroyed.

Then turn on **Rendering, Occlusion Culling, Use Occlusion Culling** in Project Settings. In code, `GSOccluderBaker.new().bake(level_root)` returns a `GSResult` whose value is the node; set `min_area`, `min_side`, `min_fill`, `inset` and `max_quads` on the baker first.

## 2. Doors: GSAreaPortal

Add a `GSAreaPortal` in the doorway (Create Node, search "portal"), set `size` to the opening (the orange box is the editor gizmo; it turns green when open), and drive it from the door:

```gdscript
@onready var portal: GSAreaPortal = $Doorway
func _on_door_opened(opened: bool) -> void:
    portal.set_open(opened)   # or set portal.open; both emit toggled(open)
```

Closed, it blocks the view, so the room behind a shut door costs nothing. It starts closed; tick `open` for a doorway with no door. `is_blocking()` says what it is doing now. Do not make `size` larger than the opening.

On a converted BSP map, `GSMapVisibility.bind_area_portals(level_root)` makes every portal that has a `key` (the map's area portal) or a `door` (the door entity's target name) drive the map's own portals too.

## 3. Check it

`godot --headless --path . res://examples/culling_demo.tscn` (the baker, the portal, the binding and a save round trip).

The occlusion scene is rebuilt in the background after a change, so the first frames after a bake or a door move still draw everything. A frame-time or draw-call test must wait about a second after changing an occluder before it counts.

## Measured

`examples/culling_demo.tscn`: eight 10 m rooms in a row, 30 props each, doorways on alternating sides, camera in the first room (`tools/shot_culling.sh --shot=<dir>` through `../gpu.sh shot`, GTX 1660 Ti, Forward+, 960×540, after a 2 s settle):

| | draw calls |
| --- | --- |
| No occluders | 283 |
| Baked occluders (80 quads) | 45 |
| Baked occluders and every portal closed | 34 |

The frame does not change: [before](img/culling_before.png) and [after](img/culling_after.png) are the same picture, which is the point. A straight line of sight through open doorways keeps drawing what it sees; closing the portals is what removes that.

## Limits

- Static geometry only: a quad does not follow a moved mesh. Rebake after moving walls, and keep movers out with `gs_no_occluder`.
- Planar groups are per mesh. Curved walls and subdivided floors produce few or no quads; add a `BoxOccluder3D` by hand there.
- Characters and particles are hidden by the same occluders; anything that must show through walls on purpose sets `ignore_occlusion_culling` on its node.

## Fewer draw calls for a box map

A map of hundreds of `StaticBody3D` boxes with one `BoxMesh` each draws one mesh per box, and the web renderer is draw-call bound. `GSMapBoxBatch.build(level, cell, skip, force)` folds the boxes of one material in one `cell`-metre square (default 64) into one `ArrayMesh`, hides the originals and leaves every body and shape as it was. Only a direct child body with one `BoxMesh` mesh and collision shapes, and an opaque `BaseMaterial3D`, is folded; a cell with one box of a material is left alone, unless the optional fifth argument `coarse` (metres, default 0 = off; Playlot passes `CELL * 4` = 256) is above `cell`: the boxes that were alone in their cell then fold with the other lone boxes of the same material in that coarser cell (`pgc_town` 621 -> 598 draws). `skip(body, mesh) -> bool` vetoes any box (breakables, doors, boxes the game restyles). It does nothing on a headless server unless `force`. `undo(level)` shows the originals again. Measured on Playlot's `pgc_town`: 1272 draws became 608 and 85.6 fps became 117.9 (staging02). `examples/box_batch_demo.tscn` is the draw budget.

## Fewer shadow draws for a converted map's props

The sun's four cascades draw every prop mesh that casts once per cascade it touches, so a prop-heavy converted map spends more draws on shadows than on what is seen. `GSMapPropShadow.fold(props)`, which `GSMapDrawnWorld` runs on a windowed client (`prop_shadow`, default true; `prop_shadow_cell` 16 m, `prop_shadow_max_tris` 20000), copies the opaque, plainly shaded prop meshes of each cell into one position-only, shadows-only mesh and turns the members' own shadow off. Each prop still draws its own colour pass, so the picture is the same (32 views compared pixel by pixel: under 0.003% of pixels differ by more than 8 of 255). `GSMapVisibility` culls a proxy like a prop and keeps a hidden member from casting twice. An imported member's LOD levels are carried into its proxy at the largest scaled member edge.

Measured with `tools/render_static_bench.sh` (32 fixed views, n=3, the laptop): an industrial deathmatch map went from 1068 objects, 704 draws and 401 shadow draws to 732, 585 and 282, at 1.59M primitives instead of 1.21M (a 32 m cell drew 566 but 2.41M). A small control-point map went from 209 objects and 175 draws to 176 and 167. Render CPU moved 1.60 to 1.46 ms on one paired run; the laptop drifts too much for a finer number.

## Fewer shadow draws for a converted map's world

Once the props are folded, most of what is left in the shadow pass is the world's own chunks: each chunk's position-only proxy (`shadow_<chunk>`) draws once per cascade it touches. `GSMapWorldShadow.fold(world)`, which `GSMapDrawnWorld` runs on a windowed client after the props (`world_shadow`, default true; `world_shadow_cell` 32 m; the statics `GSMapWorldShadow.enabled`/`default_cell` and `configure()` are the cvar hooks), merges the proxies of each cell into one shadows-only mesh and points every chunk's meta `shadow_proxy` at it. The colour pass is untouched. `GSMapVisibility` marks each chunk on or off for shadows; a fold stays on while any of its chunks is, so nothing casts twice and a fold whose chunks are all culled casts nothing. The main pass is already merged by `chunk_merge`/`auto_merge` (`chunk_target` 512).

`tools/render_static_bench.sh` measures it on staging (GTX 1660 Ti, 32 views, n=3 medians; `--opt.world_shadow=false` for off):

| Map | world_shadow | objects | draws | shadow_draws | prims | render_cpu_ms | gpu_ms |
|---|---|---|---|---|---|---|---|
| cp-orange-x3 | off | 180 | 171 | 119 | 16341 | 0.961 | 1.676 |
| cp-orange-x3 | on (32 m) | 100 | 91 | 39 | 20343 | 0.865 | 1.694 |
| cp-orange-x3 | on (64 m) | 91 | 82 | 30 | 25098 | 0.878 | 1.741 |
| dm-industrial-gamma | off | 732 | 585 | 282 | 1585574 | 1.384 | 2.135 |
| dm-industrial-gamma | on (32 m) | 689 | 542 | 239 | 1633852 | 1.282 | 2.046 |
| dm-industrial-gamma | on (64 m) | 683 | 536 | 233 | 1680682 | 1.335 | 2.143 |

The screenshots match: 0 of 23961600 pixels (cp-orange-x3) and 22 (0.0001%, dm-industrial-gamma) differ by more than 8/255 between on and off. A 64 m cell saves a few more draws but casts more triangles into more cascades and is no faster, so 32 m is the default.
