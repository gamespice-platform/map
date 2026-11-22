# Surfaces: a material per kind of surface

`GSMapSurfaces` (`addons/gs_map/surfaces/`) turns a surface kind into a `StandardMaterial3D`, so a map generator names what a thing is made of and never what colour it is.

```gdscript
var surfaces := GSMapSurfaces.new()                  # textures from this addon's folder
wall.material_override = surfaces.material(&"brick")
floor.material_override = surfaces.material(&"tile_dark", Color(0.8, 0.85, 0.9))   # a tint multiplies the photo
var res := surfaces.try_material(&"typo")            # GSResult: invalid for an unknown kind, io for a texture that did not load
```

## Kinds

`concrete`, `concrete_clean`, `plaster`, `brick`, `tile_white`, `tile_dark`, `tile_checker`, `wood_floor`, `wood_planks`, `asphalt`, `metal`, `rust`, `corrugated`, `grass`, `ground`. `GSMapSurfaces.ALIASES` maps the words a generator already uses (`wall`, `floor`, `road`, `roof`, `dirt`, `container`...) onto them; `resolve(name)` says which. `material()` always answers: an unknown kind or a missing texture draws flat grey and logs once, so one bad word in a map document costs a grey wall, not the map.

## Why it is shaped this way

- **World-space triplanar.** A code-built box has no authored UVs and a map is hundreds of boxes of every size; per-box UVs stretch a brick across a 2 m wall and a 20 m one alike. `KINDS[kind].meters` is how wide one texture is in the world, so the density is the same on every wall. It is a plain material flag, so Forward+ and the browser's Compatibility renderer draw it the same (rendered in both before commit).
- **Loaded by path, not referenced by a scene.** An imported texture a scene references is recorded at its authored location, and a delivered pack mounts elsewhere. The library calls `load()` on `root + "/<kind>/albedo.jpg"`; a game whose pack carries the textures sets `root` to the mounted folder or `path_fn` to its path rebasing function. **The default root is this addon's folder, which a pack does not carry** (a pack holds the game's tree; `res://addons/...` means the host build's copy), so a game that delivers its maps copies or links `surfaces/` into its own tree and passes that root.
- **Lightmaps bake from albedo.** The albedo is the unaltered photograph and the tint multiplies it, so what is baked is what is drawn. Triplanar has no UV for the baker to sample: check a baked map's brightness against the unbaked one before trusting it.
- **Imported lossy (WebP), not VRAM compressed**: the family has no VRAM-compressed textures yet (mobile browsers need ETC2/ASTC and the export would have to ship both), and lossy keeps the download small. The `.import` files are committed with mipmaps on and `detect_3d/compress_to=0`. A converted map's store can be shipped VRAM-compressed as a GameSpice Cloud slice instead, see [content](content.md#shared-stores-as-gs-cloud-slices).

## Size

A pack ships the imported form only (the source JPG stays behind, [publishing.md](../../gs-cloud/docs/publishing.md#the-source-of-an-imported-asset-stays-behind)), so the right column is what a map costs to download; a map using six kinds is about 2-3 MB.

| Kind | Source JPG | Imported (ships) |
| --- | --- | --- |
| asphalt | 1.10 MB | 0.75 MB |
| brick | 1.05 MB | 0.73 MB |
| concrete | 0.92 MB | 0.59 MB |
| concrete_clean | 0.50 MB | 0.21 MB |
| corrugated | 0.62 MB | 0.23 MB |
| grass | 1.63 MB | 1.27 MB |
| ground | 1.78 MB | 1.23 MB |
| metal | 0.52 MB | 0.32 MB |
| plaster | 0.79 MB | 0.41 MB |
| rust | 0.63 MB | 0.28 MB |
| tile_checker | 0.34 MB | 0.16 MB |
| tile_dark | 0.54 MB | 0.28 MB |
| tile_white | 0.25 MB | 0.08 MB |
| wood_floor | 0.51 MB | 0.21 MB |
| wood_planks | 0.63 MB | 0.34 MB |
| **total** | 11.81 MB | 7.08 MB |

Credits and licences (all ambientCG, CC0): `addons/gs_map/surfaces/CREDITS.md`.

## Delivering to players: a game vendors what it uses

The client shell bundles gs-map, so the 12 MB of textures here must not ride in the addon to every player. A game copies exactly the kinds it draws into its own tree with `tools/sync-surfaces.sh <game> assets/surfaces [kind...]` (the kinds are written to `<dest>/kinds.txt`, so a later `sync-surfaces.sh <game> assets/surfaces` and `--check` know the list; `--check` copies nothing and exits 1 if a file is missing or differs), commits the copy with its `.import` files, passes `ZzPaths.rebase("res://assets/surfaces")` (its mounted root) to `GSMapSurfaces.new(root)`, and lists the folder in `sides.json` as client-only so a server does not fetch it. A game with a lightmap bakes with an instance whose `metallic_scale` is 0: a lightmap holds diffuse light only and a metallic surface has almost none, so a baked corrugated roof drew nearly black. Game-zombie-zone is the first (13 kinds, 6.2 MiB imported, [its design notes](../../game-zombie-zone/docs/design.md)).

## Not here

No decals, no blood or graffiti, no rubble models: CC0 sources for those were not found (ambientCG's decal category is stains, road markings and manhole covers; Poly Haven has barriers, barrels, tyres and a chain-link fence, but no pallets or rubble).

## See-through kinds in converted maps

A converted map's texture map (`gs-map-convert/gsbsp/source_textures.tsv`) can name a see-through generic: `fence` (diamond mesh), `grate`, `bars` and `ladder` are drawn alpha-scissored from a pattern `GSMapBspMesh.cutout_texture` paints in code, `foliage_card` is a leaf cutout, `shield` is an additive glow, and `glass*` are the tinted panes. `invisible` marks fog and light cards, which are skipped. A `decal_*` generic (`decal_lines`, `decal_graffiti`, `decal_sign`, `decal_fade`, `decal_radial`, `decal_patch`) goes into the record as `decal` and is drawn alpha-blended over the face it lies on, pulled toward the camera by `GSMapBspMesh.decal_depth_bias` metres per metre (0 = none), from a pattern `GSMapBspMesh.decal_texture` draws in code (`DECAL_LOOKS` sets each kind's colour), lit by the bake like the face under it; with `original_textures` an internal pack draws the map's own decal texture instead. None needs a licence file.

**Cutouts keep their coverage in the mips** (`GSMapBspMesh.keep_coverage`, applied to every generated cutout). A thin line averages below the 0.5 scissor threshold a mip or two down, so a fence vanished at distance; each mip's alpha is rescaled so the share of texels past the threshold equals the top level's, and a level with no line left is left to alpha-to-coverage. The result is a thinner, fainter-edged line, never a hole.

**Sprites, glows, cones and decals are `GSMapFx`** (`addons/gs_map/bsp/gs_map_fx.gd`): `build(records)` takes the source document's entity records and returns a node with `env_sprite`/`env_lightglow` as additive billboards, `point_spotlight` as a faint additive cone (a few also a real `SpotLight3D`), `infodecal` as `Decal` nodes laid on the nearest surface. Textures are generated in code, so no art ships. Each kind has a per-map cap (`max_sprites` 400, `max_cones` 120, `max_lights` 6, `max_decals` 120; sprites and cones are culled by `view_range` in the engine, so only the six real `SpotLight3D` are a realtime cost) spread evenly over the entities when a map has more, and a view range (`view_range` 60 m, `decal_range` 22 m); `stats` says what was drawn and left out. The game supplies `ray_fn(from, to) -> {position, normal}` (decals need it, cones stop at a wall with it) and `unit_scale`. Nothing here is gameplay and a headless run has no use for it.

Sky: `GSMapBspMesh.sky_kind(sky_name)` picks `clear`, `cloudy`, `overcast`, `dusk` or `twilight` (the dark one) (night and space names return empty, so a game keeps its procedural night sky), and `sky_panorama(root)` loads the matching panorama from `addons/gs_map/sky/` (Poly Haven, CC0; credits beside the files). `GSMapBspMesh.sky_material_for(sky_name, root)` returns the ready `PanoramaSkyMaterial` (null for night) for a game that lights its own map. A game that vendors the folder passes its own root.

## Drawing a lightmapped world (any game)

A pack from `bsp.py regen` carries the author's baked light (gs-bsp-mesh v2). The adoption is two lines after the materials are built: `surfaces.use_lightmap = lightmaps_enabled` before `world_material_for`, and after the world node is in the tree `GSMapLitWorld.attach(self, world, environment, lamps_to_free, lightmaps_enabled)`. The second frees the live lamps the bake already holds (pass only lamps that are not dynamic; the converter keeps no light styles, so a style-driven light is not in the bake), and drives the Environment's ambient from `GSMapBspMesh.ambient_at` at the camera so props, characters and the viewmodel match the baked scene. It returns null (nothing changed) for a v1 pack or with the option off. A world drawn somewhere other than the origin passes its node as the sixth argument, so the camera is sampled in the pack's frame. Do not box-bake or `_unbake` for it. The shader is lit: the bake is emission, the scene's sun adds shadowed diffuse (its energy is floored on a lightmapped world and fades where the bake is bright) and an ambient floor keeps an outdoor map with a near-black bake (zm_house_outbreak) from drawing black.

## Drawn over a game's own collision

A game whose map is its own document (boxes, doors, catalogue props) and wants a converted pack only as what is seen uses `GSMapDrawnWorld`: `await GSMapDrawnWorld.read(prefix, cloud)` loads the pack and fetches its store slice, then `GSMapDrawnWorld.attach(parent, world, {transform, surfaces_root, environment, lamps})` draws model 0 lightmapped, adds its reflection probes and culling, and returns the credits line. Brush entities and the pack's props are off by default (`only_world`, `props`), because a door or a breakable window the document did not keep would be drawn where a player walks through. The game removes its own box meshes and keeps everything that collides.

A box-document game without a converted pack gets baked light from `GSMapBoxBake` (`addons/gs_map/bake/`, needs GameSpice Lighting API level 5): the game builds its box meshes with `new_sheet()` / `add_faces()` / `commit()` (deterministic UV2 and a lightmap size hint) and marks them `META_BAKEABLE`; an offline tool calls `bake_scene(drawn, lighting, fingerprint, out_path, settings, parts)` to make the editor-bakeable scene (surfaces emit a little, lamps are static, the sun stays dynamic, ambient is a custom-colour sky), and at runtime `attach(host, path, fingerprint, lamps)` loads the result when the fingerprint of the document still matches. Settings per map: `quality`, `bounces`, `texel_scale`, `ambient_gain`, `bounce_energy`, `emit` (open maps want a low `ambient_gain` and `emit`). The lightmap holds diffuse only, so attach dulls metal. The reference user is game-hide-n-seek (`tools/bake_lightmaps.sh`).

## Texture memory

`tools/texture_audit.sh` on `ze_biohazard_manor` (253 world PBR sets, 176 library models, model textures uncapped): 1179 MB of texture memory, 1269 MB video memory, RSS 2.5 GB. World normals 338 MB (RGTC_RG), world albedo 169, world roughness 169, world AO 134, model albedo 119, model normal 97, model ORM 103, lightmap 16, the rest small. The world sets are 1k each, so they are three quarters of the total, not the models.

`half_res_masks` (roughness and AO at half size, on by default; frames of the manor differ by at most 5 of 255, mean 0.03) takes 303 MB to 76 MB: 1179 to 947 MB (-20%). It slices the top mip off the compressed texture, so it works for decoded, imported and baked textures and every format alike. Opaque RGBA images are compressed as RGB (DXT1 or ETC2 RGB), which halves a model albedo that carries a solid alpha channel (about 5 MB here). Measured and not worth it: eliding flat maps (about 12 MB), sharing by content hash (-9 MB), RG normals for models (+100 MB). `half_res_normals` (on by default, the same top-mip slice, no store change: the store's import settings are `gs-map-convert/gsbsp/storepack.py` and stay full size) takes the manor's world normals from 338 to 85 MB: 947 to 689 MB (-27%), and ze_jurassicpark 292 to 223 MB. A daylight frame at ground level on ze_jurassicpark differs by 0.19 of 255 on average (0.011% of pixels over 8, max 40); the night manor frames differ by at most 1. Albedo and the model ORM are left at full size. `tools/texture_audit.sh <world> --fullnormals` turns it off.

`model_half_masks` and `model_half_normals` (`GSMapBspMesh`, on by default) do the same for a library model's roughness, metallic, AO and normal maps inside `slim_model_textures`: a decoded glTF image is resized to half before it is capped, mip-mapped and compressed, an already compressed one loses its top mip (no re-encode), and a glTF's shared ORM image stays one texture. Models that embed the same image bytes share one slimmed texture (keyed on a SHA-256 of the decoded bytes plus size, format, halving and cap; mutex-guarded for the load threads; cleared by `clear_cache` and when `build_props` ends). Albedo and emission are untouched. This path runs only when `GSMapBspMesh.model_texture_max` is 0 or more (it is -1, off, in every game today; the audit turns it on), so a game gains nothing until it sets that cap. On the manor the model normals go from 97 to 24 MB and the model ORM from 103 to 26 MB: 689 to 538 MB of texture memory (-22%), the world's own textures unchanged. Frames of 8 library props on ze_jurassicpark (daylight, trees, truck, container, boulder, fence) differ from full size by 0.001 to 0.3 of 255 on average, except a grazing-angle shimmer band on the horizon of one frame (mean 0.97, max 132, equally noisy in both) and foliage edges (max 156 on a tree); side by side with an amplified difference they look the same. Eight prop frames of the manor (night) differ by at most 43, mean at most 0.03. Rendered on dev02 with llvmpipe (the worlds are outside the repository, so a GPU box cannot reach them). `tools/texture_audit.sh <world> --fullmodelmasks --fullmodelnormals` and `bsp_world_shot` with `--slimmodels` give the full-size side.


## The map's own textures (internal `_orig` packs)

`GSMapSurfaces.use_original_textures` (default off) draws a surface with the map's own texture where its record has `orig` (a PNG beside the pack, written by `gs-map-convert` `bsp.py regen <map> --orig-textures --name <map>_orig`). The mesh UVs already are source coordinate over source texture size, so original tiling and alignment come out as authored: the unlit path is a plain `StandardMaterial3D`, the lit path is `lightmapped.gdshader` with `use_uv` on. A surface with no `orig`, or a missing file, keeps its free replacement. Such a pack is internal, never published, never committed.

## Texture quality tiers

`GSMapTextureTier.apply(surfaces, quality, bytes_at_reference, free_bytes)` maps the video setting's texture quality (0 low, 1 medium, 2 high, 3 ultra) to `max_texture_size` (512, 1024, 2048, unlimited) and the half-size masks and normals. Pass the art's size measured at 2048 and the browser's free quota (`DotCloudStore.free_bytes()`, `-1` when unmeasured) and it steps the tier down until the art fits `quota_share` (0.8) of it, logging a warning; `fit()` returns `fits: false` when even low is over, which the game must show the player. Tables (`max_sides`, `half_masks`, `half_normals`) and `quota_share` are static and configurable; 0 is unlimited and `quota_share` 0 turns the check off. A wrong level or a short table is refused with an error, changing nothing. `GSMapTextureTier.follow(settings)` (once, with the game's settings store) keeps `current_quality` at the player's `texture_quality`, and the surfaces the library builds itself (`GSMapDrawnWorld`, `GSMapWorld`, `GSMapLocalMaps.surfaces_for`) apply it; -1 (never followed) leaves them as before. Check: `examples/texture_tier_selftest.tscn`.
