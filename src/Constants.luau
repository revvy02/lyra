--!strict

local Constants = {
	RECORD_SCOPE = "lyra/records",
	TX_SCOPE = "lyra/tx",
	SHARD_SCOPE = "lyra/shards",
	MAX_CHUNK_SIZE = 4_000_000,
	LOCK_DURATION_SECONDS = 150,
	LOCK_ACQUIRE_ATTEMPTS = 8,
	AUTOSAVE_INTERVAL_SECONDS = 120,
}

return Constants
