--!strict

local Constants = {
	RECORD_SCOPE = "lyra/records",
	TX_SCOPE = "lyra/tx",
	SHARD_SCOPE = "lyra/shards",
	MAX_CHUNK_SIZE = 1000,
	LOCK_DURATION_SECONDS = 60,
	LOCK_ACQUIRE_ATTEMPTS = 8,
	AUTOSAVE_INTERVAL_SECONDS = 30,
}

return Constants
