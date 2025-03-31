--!strict
--[=[
	Common types shared among different modules.

	@class Types
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local t = require(ReplicatedStorage.Packages.t)

--[[
	Represents a single operation within a JSON Patch array.
	Used for describing changes between data states.

	@interface PatchOperation
	@field op "add" | "replace" | "remove" The operation type.
	@field path string A JSON Pointer string indicating the target location.
	@field value any (Optional) The value to add or replace (used for "add" and "replace").

	@within Types
]]
export type PatchOperation =
	{ op: "add", path: string, value: any }
	| { op: "replace", path: string, value: any }
	| { op: "remove", path: string }

--[[
	An array of PatchOperation objects representing the changes made during a transaction.

	@type TxPatch {PatchOperation}

	@within Types
]]
export type TxPatch = { PatchOperation }

--[[
	Holds information about the state of data potentially involved in a transaction.
	Used by the `Transactions` module to determine the correct data to return during reads.

	@interface TxInfo
	@field committedData any The last known data state that was successfully saved
		to the primary DataStore record *before* the transaction identified by `txId` began.
	@field txId string? The unique identifier of the transaction currently attempting
		to modify this data. If `nil`, no transaction is active or the last one completed
		and was cleaned up.
	@field txPatch TxPatch? The set of changes (JSON Patch) applied by the transaction
		identified by `txId`. This is used to reconstruct the final state if the
		transaction is confirmed as committed.

	@within Types
]]
export type TxInfo = {
	committedData: any,
	txId: string?,
	txPatch: TxPatch?,
}

--[[
	Represents the stored data, abstracting away the sharding mechanism.

	If the data was small enough, it's stored directly in the `data` field.
	If the data was large and sharded, `shard` and `count` are present instead,
	pointing to the location and number of data shards stored separately.

	@interface File
	@field data any The actual data, if it was stored directly (not sharded).
	@field shard string? The unique identifier for the set of shards, if the data was sharded.
	@field count number? The total number of shards, if the data was sharded.

	@within Types
]]
export type File = {
	data: any,
} & {
	shard: string,
	count: number,
}

--[[
	The structure of the primary record stored in the main DataStore for each key.
	This record contains metadata and a reference (`File`) to the actual user data.

	@interface DataStoreRecord
	@field appliedMigrations {string}? A list of names of migration steps that have
		already been successfully applied to the data associated with this record. Can be nil
		if no migrations have been applied.
	@field file File A `File` object representing the actual user data. This might contain
		the data directly or point to shards.
	@field orphanedFiles {File} A list of sharded `File` objects that are no longer referenced
		by any active record. This is used for cleanup and garbage collection of unused data.

	@within Types
]]
export type DataStoreRecord = {
	appliedMigrations: { string },
	file: File,
	orphanedFiles: { File },
}

--[=[
	Represents a migration step that can be applied to data when loading it.
	Each step has a name and an `apply` function that takes the data as input
	and returns a modified version of the data.

	@interface MigrationStep
	.name string -- The name of the migration step
	.apply (data: { [string]: any }) -> { [string]: any } -- The function to apply the migration step

	@within Types
]=]
export type MigrationStep = {
	name: string,
	apply: (data: { [string]: any }) -> { [string]: any },
}

--[[
	Contains all the contextual information and dependencies required for a `Store`
	or `PlayerStore` instance to operate. This includes configuration, service instances,
	callbacks, and underlying storage objects.

	@interface StoreContext<T>
	@field name string The name of the store, used for logging and potentially identifying DataStore keys.
	@field template T A default template object representing the initial state for new data entries.
	@field schema (value: any) -> (boolean, string?) A validation function (like one created by `t`)
		used to check if loaded or modified data conforms to the expected structure. Returns `true`
		if valid, or `false` and an error message string if invalid.

	@field migrationSteps {MigrationStep}? A list of migration steps to apply to data
		when it's loaded, based on the `appliedMigrations` field in the `DataStoreRecord`.
	@field importLegacyData ((key: string) -> any?)? An optional function to load data from a
		legacy storage system when a key is accessed for the first time in this store.

	@field dataStoreService DataStoreService The Roblox DataStoreService instance.
	@field memoryStoreService MemoryStoreService The Roblox MemoryStoreService instance.

	@field changedCallbacks { (key: string, newData: T, oldData: T?) -> () } A list of
		functions to call whenever data for a key is successfully changed. Provides the key,
		the new data state, and the previous data state (if available).
	@field logger Logger A `Logger` instance used for internal logging within the store and its components.
	@field onLockLost ((key: string) -> ())? An optional callback function triggered if the
		distributed lock for a key is lost unexpectedly (e.g., due to expiration or external interference).

	@field recordStore DataStore The DataStore used to store `DataStoreRecord` objects.
	@field shardStore DataStore The DataStore used to store the actual data shards for large files.
	@field txStore DataStore The DataStore used to store transaction status markers (`txId` keys).
	@field lockHashMap MemoryStoreHashMap The MemoryStore HashMap used for managing distributed locks.

	@field disableReferenceProtection boolean If true, disables the deep copying mechanism used to
		prevent accidental modification of internal state references returned by `get()`. Use with caution,
		only if performance is critical and mutation risks are understood and managed.

	@within Types
]]
export type StoreContext<T> = {
	name: string,
	template: T,
	schema: (value: any) -> (boolean, string?),

	migrationSteps: { MigrationStep },
	importLegacyData: ((key: string) -> any?)?,

	dataStoreService: DataStoreService,
	memoryStoreService: MemoryStoreService,

	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () },
	logger: Logger,
	onLockLost: ((key: string) -> ())?,

	recordStore: DataStore,
	shardStore: DataStore,
	txStore: DataStore,
	lockHashMap: MemoryStoreHashMap,

	disableReferenceProtection: boolean,
}

-- Validation check for TxInfo structure using 't' library.
local txInfoCheck = t.some(
	t.strictInterface({ committedData = t.any }),
	t.strictInterface({ committedData = t.any, txId = t.string, txPatch = t.any })
)
-- Validation check for File structure using 't' library.
local fileCheck = t.some(t.strictInterface({ data = t.any }), t.strictInterface({ shard = t.string, count = t.number }))

--[=[
	Represents the different log levels available for logging messages.

	@interface LogLevel
	.fatal "fatal"
	.error "error"
	.warn "warn"
	.info "info"
	.debug "debug"
	.trace "trace"

	@tag enum
	@within Types
]=]
export type LogLevel = "fatal" | "error" | "warn" | "info" | "debug" | "trace"

--[=[
	Represents a log message sent to the logger's callback function.

	@interface LogMessage
	.message string
	.level LogLevel
	.context { [string]: any }?

	@within Types
]=]
export type LogMessage = {
	message: string,
	level: LogLevel,
	context: { [string]: any }?,
}

--[[
	Defines the methods available on a Logger instance.

	@interface LoggerImpl (Internal)
	@field __index Points to LoggerImpl itself for method lookup.
	@field log (self: Logger, level: LogLevel, message: string, context: { [string]: any }?) -> ()
		Sends a log message to the configured callback.
	@field extend (self: Logger, context: { [string]: any }) -> Logger
		Creates a new Logger instance with additional context merged into the existing context.

	@within Types
]]
export type LoggerImpl = {
	__index: LoggerImpl,

	log: (self: Logger, level: LogLevel, message: string, context: { [string]: any }?) -> (),
	extend: (self: Logger, context: { [string]: any }) -> Logger,
}

--[[
	Defines the internal properties stored within a Logger instance.

	@interface LoggerProps (Internal)
	@field _logCallback (logMessage: LogMessage) -> () The function called when `log` is invoked.
	@field _context { [string]: any } The persistent context associated with this logger instance.

	@within Types
]]
export type LoggerProps = {
	_logCallback: (logMessage: LogMessage) -> (),
	_context: { [string]: any },
}

--[[
	A structured logger object.

	Provides methods to log messages at different levels (`fatal`, `error`, `warn`, `info`, `debug`, `trace`)
	and allows extending the logger with additional context fields that will be included
	in subsequent log messages. The actual logging is delegated to a callback function
	provided during instantiation (see `Log.luau`).

	@class Logger

	@within Types
]]
export type Logger = typeof(setmetatable({} :: LoggerProps, {} :: LoggerImpl))

--[[
	A handle returned by retry utility functions like `hashMapRetry`.
	It bundles the core Promise with a way to cancel the retry operation.

	When the `cancel` function is called, instead of cancelling the Promise itself,
	the retry mechanism is stopped, and the Promise is rejected with a cancellation error
	when the next retry attempt is made.

	@interface RetryHandle<T>
	@field promise T The Promise representing the asynchronous operation being retried.
		This promise resolves or rejects based on the outcome of the operation after retries.
	@field cancel () -> () A function that can be called to signal cancellation. If called,
		the retry mechanism will stop further attempts and reject the `promise`.

	@within Types
]]
export type RetryHandle<T> = {
	promise: T,
	cancel: () -> (),
}

return {
	txInfoCheck = txInfoCheck,
	fileCheck = fileCheck,
}
