class_name GSMapDataConfig
extends GSConfig

## Which [GSMapDataStore] a server uses, layered as everywhere: defaults < file < environment (DOT_MAP_DATA_*) < argv.

## `file`, `sql` or `http`.
@export var map_data_store := "file"
## Root folder of the file store.
@export var map_data_path := "user://map_data"
## Base URL of the backbone for the http store.
@export var map_data_url := ""
## Bearer token for the http store. Only the config file may set it.
@export var map_data_token := ""
## Table of the sql store.
@export var map_data_table := GSMapDataSqlSchema.DEFAULT_TABLE


func env_prefix() -> String:
	return "DOT_"


func cli_prefix() -> String:
	return "--"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["map_data_token"])


func validate() -> GSResult:
	if not map_data_store in ["file", "sql", "http"]:
		return GSResult.fail(GSError.CODE_INVALID, "map_data_store must be file, sql or http.")
	if map_data_store == "sql" and not GSMapDataBundle.is_safe_id(map_data_table):
		return GSResult.fail(GSError.CODE_INVALID, "map_data_table is not a plain identifier.")
	if map_data_store == "http":
		var https := map_data_url.begins_with("https://")
		var loopback := map_data_url.begins_with("http://localhost") or map_data_url.begins_with("http://127.0.0.1")
		if not https and not loopback:
			return GSResult.fail(GSError.CODE_INVALID, "map_data_url must be https (http only for localhost).")
	return GSResult.success(null)


## The configured store. The sql store needs a GameSpice SQL driver and the http store a client with `request`,
## because neither is named here. Fails when the one it needs is null.
func make_store(sql_driver = null, http_client: Object = null) -> GSResult:
	var ok := validate()
	if not ok.ok:
		return ok
	match map_data_store:
		"sql":
			if sql_driver == null:
				return GSResult.fail(GSError.CODE_STATE, "map_data_store is sql but no driver was given.")
			return GSResult.success(GSMapDataSql.new(sql_driver, map_data_table))
		"http":
			if http_client == null:
				return GSResult.fail(GSError.CODE_STATE, "map_data_store is http but no client was given.")
			if "base_url" in http_client:
				http_client.set("base_url", map_data_url)
			return GSResult.success(GSMapDataHttp.new(http_client, map_data_token))
	return GSResult.success(GSMapDataFile.new(map_data_path))
