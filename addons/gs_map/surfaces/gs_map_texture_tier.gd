class_name GSMapTextureTier
extends RefCounted
## Texture resolution picked by the game's video setting (texture quality 0 low .. 3 ultra), and stepped down when the browser's storage quota cannot hold the maps' art at the asked tier. Games call [method apply] on their [GSMapSurfaces] after the video settings load or change; they never keep their own table.

const CHANNEL := &"gs_map.texture_tier"
const LEVELS := 4
## Pixels on the longest side the cap of one tier is measured against ([member GSMapSurfaces.max_texture_size] default, and what the RSI texture audit calls tier high).
const REFERENCE_SIDE := 2048

## Longest texture side per quality level; 0 is unlimited. Edit to retune: the arrays must hold [constant LEVELS] entries or [method apply] refuses.
static var max_sides: Array[int] = [512, 1024, 2048, 0]
## Whether roughness and AO keep half size, per level.
static var half_masks: Array[bool] = [true, true, true, false]
## Whether normal maps keep half size, per level.
static var half_normals: Array[bool] = [true, true, true, false]
## Share of the browser's free quota the art may take; 0 turns the quota check off.
static var quota_share: float = 0.8


## The tier settings for [param quality] as {max_size, half_masks, half_normals}; {} (with an error pushed) when the table or the level is wrong.
static func settings(quality: int) -> Dictionary:
	if quality < 0 or quality >= LEVELS or max_sides.size() != LEVELS or half_masks.size() != LEVELS or half_normals.size() != LEVELS:
		push_error("GSMapTextureTier: quality %d outside 0..%d or a tier table is not %d long" % [quality, LEVELS - 1, LEVELS])
		return {}
	return {"max_size": max_sides[quality], "half_masks": half_masks[quality], "half_normals": half_normals[quality]}


## Memory of art measured at [constant REFERENCE_SIDE], scaled to [param quality]'s cap (a side cap of half is a quarter of the bytes; unlimited keeps them).
static func scaled_bytes(bytes_at_reference: int, quality: int) -> int:
	var cap := max_sides[quality]
	if cap <= 0 or cap >= REFERENCE_SIDE:
		return bytes_at_reference
	var r := float(cap) / float(REFERENCE_SIDE)
	return int(float(bytes_at_reference) * r * r)


## The highest quality at or below [param wanted] whose art ([param bytes_at_reference] scaled) fits [member quota_share] of [param free_bytes]. Returns {quality, fits, wanted}; [code]fits[/code] is false when even level 0 is over (a warning is logged, the game must tell the player). A negative [param free_bytes] (unmeasured), 0 [member quota_share] or 0 bytes skips the check.
static func fit(wanted: int, bytes_at_reference: int, free_bytes: int) -> Dictionary:
	if settings(wanted).is_empty():
		return {"quality": clampi(wanted, 0, LEVELS - 1), "fits": false, "wanted": wanted}
	if free_bytes < 0 or quota_share <= 0.0 or bytes_at_reference <= 0:
		return {"quality": wanted, "fits": true, "wanted": wanted}
	var budget := int(float(free_bytes) * quota_share)
	var q := wanted
	while q > 0 and scaled_bytes(bytes_at_reference, q) > budget:
		q -= 1
	var ok := scaled_bytes(bytes_at_reference, q) <= budget
	if q != wanted or not ok:
		GSLog.warn(CHANNEL, "texture quality lowered for the browser quota" if ok else "art does not fit the quota even at the lowest texture quality",
				{"wanted": wanted, "used": q, "need": scaled_bytes(bytes_at_reference, q), "budget": budget})
	return {"quality": q, "fits": ok, "wanted": wanted}


## Sets [param surfaces]' cap and half-size options for [param quality], stepped down by [method fit] when [param free_bytes] is known. Returns [method fit]'s result ({} when the table is wrong, nothing changed).
static func apply(surfaces: GSMapSurfaces, quality: int, bytes_at_reference: int = 0, free_bytes: int = -1) -> Dictionary:
	if settings(quality).is_empty():
		return {}
	var f := fit(quality, bytes_at_reference, free_bytes)
	var s := settings(int(f["quality"]))
	surfaces.max_texture_size = int(s["max_size"])
	surfaces.half_res_masks = bool(s["half_masks"])
	surfaces.half_res_normals = bool(s["half_normals"])
	return f
