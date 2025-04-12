--[[
	@module Constants

	Defines constant values used throughout the Lyra library.
]]

-- Estimated bytes reserved within the DataStore value for Lyra's internal metadata
-- (like appliedMigrations, orphanedFiles list, and File object overhead when sharded).
-- This ensures that the actual user data shards stay safely within the DataStore limits.
local INTERNAL_SPACE_RESERVE_BYTES = 10_000

local Constants = {
	-- Scope prefix used for keys storing the main DataStoreRecord objects.
	RECORD_SCOPE = "lyra/records",
	-- Scope prefix used for keys storing transaction status markers in a DataStore.
	TX_SCOPE = "lyra/tx",
	-- Scope prefix used for keys storing data shards in a DataStore.
	SHARD_SCOPE = "lyra/shards",
	-- Scope prefix used for keys storing lock information in a MemoryStore HashMap.
	LOCK_SCOPE = "lyra/locks",

	-- Maximum size (in bytes) for a single data shard stored in DataStore.
	-- Derived from the Roblox DataStore value limit (4MB = 4,000,000 bytes) minus
	-- a reserved amount for Lyra's internal metadata within the main record.
	MAX_CHUNK_SIZE = 4_000_000 - INTERNAL_SPACE_RESERVE_BYTES,

	-- How often (in seconds) a held lock should be refreshed in MemoryStore
	-- to prevent it from expiring while still actively being used.
	-- Should be significantly shorter than LOCK_DURATION_SECONDS.
	LOCK_REFRESH_INTERVAL_SECONDS = 60,

	-- The initial time-to-live (TTL) duration (in seconds) for a lock acquired in MemoryStore.
	-- If the lock isn't refreshed within this time, it will automatically expire.
	-- Must be longer than LOCK_REFRESH_INTERVAL_SECONDS to allow time for refreshes.
	LOCK_DURATION_SECONDS = 90,

	-- The maximum number of times to attempt acquiring a lock before giving up.
	-- Currently unused in implementation.
	LOCK_ACQUIRE_ATTEMPTS = 8,

	-- How often (in seconds) the automatic saving mechanism should attempt to
	-- save dirty session data.
	AUTOSAVE_INTERVAL_SECONDS = 5 * 60, -- 5 minutes
}

return Constants
