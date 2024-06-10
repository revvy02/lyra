--!strict

local Constants = {
	RECORD_SCOPE = "mix/records",
	TX_SCOPE = "mix/tx",
	SHARD_SCOPE = "mix/shards",
	MAX_CHUNK_SIZE = 1000,
	LOCK_DURATION_SECONDS = 60,
	LOCK_ACQUIRE_ATTEMPTS = 8,
}

return Constants
