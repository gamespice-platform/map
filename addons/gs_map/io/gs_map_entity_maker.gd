class_name GSMapEntityMaker
extends GSMapEntity

## env_entity_maker: ForceSpawn (and the ForceSpawnAt* inputs) asks the point_template its EntityTemplate key names for a
## copy of its set, with this entity as the maker, so the game's [code]template_spawn[/code] events carry [code]maker[/code]
## and the copies go where the maker stands; then fires OnEntitySpawned, or OnEntityFailedSpawn when no template has the name.
## ForceSpawnAtEntityOrigin also sends a [code]maker_at[/code] event with the entity named by its parameter, for a game
## that places the set there instead.


func _input(io: RefCounted, name: String, param: String, activator: Variant, _caller: Variant) -> bool:
	match name:
		"forcespawn", "forcespawnatentityorigin", "forcespawnatentitycenter", "forcespawnatposition":
			if not enabled:
				return true
			if name != "forcespawn":
				io.event("maker_at", {"entity": index, "input": name, "at": param})
			_spawn(io, activator)
		_:
			return false
	return true


func _spawn(io: RefCounted, activator: Variant) -> void:
	var spawned := false
	for t: GSMapEntity in io.find(key("entitytemplate")):
		if t is GSMapTemplate and t.accept(io, "ForceSpawn", "", activator, self):
			spawned = true
	fire(io, "OnEntitySpawned" if spawned else "OnEntityFailedSpawn", activator)
