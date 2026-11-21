class_name GSMapVolumes
extends RefCounted

## Every volume of a converted map, stepped from the game's tick: [code]GSMapVolumes.build(entities, io)[/code], then [code]vols.step(bodies)[/code] each tick after [code]io.advance(1)[/code].
## Ladders and water are boxes for the controller ([method ladder_boxes], [method water_boxes]), not areas, so a client replaying prediction gets the server's answer.
## Everything else reaches the game through [GSMapIO]'s callables: [member GSMapIO.damage_fn], [member GSMapIO.move_fn], [member GSMapIO.event_fn].

var io: GSMapIO
var nodes: Array[GSMapVolumeNode] = []
## Seconds between hits from a burning fire, and its default radius (source units).
var fire_period := 0.5
var fire_radius_units := 64.0

var _mover_nodes: Array[GSMapMoverNode] = []
var _movers_checked := false
var _scapes: Array[GSMapSoundscape] = []
var _scapes_checked := false
var _heard: Dictionary = {}


## One node per volume of [param entities], each joined to its entity in [param io] by index.
static func build(entities: GSMapEntities, io: GSMapIO, destinations: Dictionary = {}) -> GSMapVolumes:
	var vols := GSMapVolumes.new()
	vols.io = io
	if not destinations.is_empty():
		io.destinations = destinations
	for v: GSMapVolume in entities.volumes:
		vols.nodes.append(GSMapVolumeNode.new(v, io.entity_of(v.entity) if v.entity >= 0 else null))
	return vols


## Runs one step for [param bodies] (see [method GSMapVolumeNode.step]), then the area damage
## explosions and fires queued.
func step(bodies: Array) -> void:
	for n in nodes:
		n.step(io, bodies)
	_fires(bodies)
	_blasts(bodies)
	_soundscapes(bodies)
	_movers(bodies)
	io.settle()


## The boxes of every active ladder brush, for [code]GSFpsLadderMode.volumes[/code].
func ladder_boxes() -> Array[AABB]:
	return _boxes("ladder")


## The boxes of every active water brush (slime too), for [code]GSFpsSwimMode.volumes[/code].
func water_boxes() -> Array[AABB]:
	return _boxes("water")


func _boxes(kind: String) -> Array[AABB]:
	var out: Array[AABB] = []
	for n in nodes:
		if n.volume.kind == kind and n.active():
			out.append_array(n.volume.brush_boxes())
	return out


## Bodies in the way of a moving door, lift or spinner are pushed, then hurt and turned back.
func _movers(bodies: Array) -> void:
	if not _movers_checked:
		_movers_checked = true
		for e: GSMapEntity in io.entities:
			if e is GSMapMoverNode:
				_mover_nodes.append(e)
	for m: GSMapMoverNode in _mover_nodes:
		m.push_bodies(io, bodies)


## The nearest enabled soundscape that covers each player; an event when it changes.
func _soundscapes(bodies: Array) -> void:
	if _scapes_checked and _scapes.is_empty():
		return
	if not _scapes_checked:
		_scapes_checked = true
		for e: GSMapEntity in io.entities:
			if e is GSMapSoundscape:
				_scapes.append(e)
		if _scapes.is_empty():
			return
	for info: Dictionary in bodies:
		if str(info.get("kind", "player")) != "player":
			continue
		var best: GSMapSoundscape = null
		var best_d := INF
		var at: Vector3 = info["position"]
		for s: GSMapSoundscape in _scapes:
			if not s.alive or not s.enabled or not s.covers(io, at, info["id"]):
				continue
			var d := -1.0 if s.listeners.has(info["id"]) else at.distance_to(s.origin(io))
			if d < best_d:
				best_d = d
				best = s
		var id: Variant = info["id"]
		var prev: Variant = _heard.get(id)
		if best == prev:
			continue
		_heard[id] = best
		if best != null:
			best.fire(io, "OnPlay", info.get("body"))
		io.event("soundscape", {"body": info.get("body"), "name": best.resolved_name(io) if best != null else "",
				"entity": best, "positions": best.positions(io) if best != null else []})


func _blasts(bodies: Array) -> void:
	var queue := io.area_damage
	io.area_damage = []
	for b: Dictionary in queue:
		for info: Dictionary in bodies:
			var d := ((info["position"] as Vector3) + Vector3(0.0, 0.9, 0.0)).distance_to(b["origin"])
			var r: float = b["radius"]
			if d <= r:
				io.damage(info.get("body"), float(b["amount"]) * (1.0 - 0.5 * d / maxf(r, 0.001)), str(b["kind"]), b["source"])


func _fires(bodies: Array) -> void:
	if io.now % maxi(1, io.ticks_for(fire_period)) != 0:
		return
	for e: GSMapEntity in io.entities:
		if e is GSMapEffect and e.alive and e.enabled and e.classname.to_lower() == "env_fire" and e.key_float("damagescale", 1.0) > 0.0:
			var at := e.origin(io)
			var r := maxf(e.key_float("firesize", fire_radius_units), 1.0) * io.unit_scale
			for info: Dictionary in bodies:
				if ((info["position"] as Vector3) + Vector3(0.0, 0.9, 0.0)).distance_to(at) <= r:
					io.damage(info.get("body"), 10.0 * fire_period * e.key_float("damagescale", 1.0), "burn", e)


func describe() -> Dictionary:
	var counts := {}
	for n in nodes:
		counts[n.volume.kind] = int(counts.get(n.volume.kind, 0)) + 1
	return {"volumes": nodes.size(), "kinds": counts}
