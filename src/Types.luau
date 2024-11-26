--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local t = require(ReplicatedStorage.Packages.t)

export type TxInfo = {
	committedData: any,
	txId: string?,
	txData: any?,
}

export type File = {
	data: any,
} & {
	shard: string,
	count: number,
}

export type LockInfo = {
	id: string,
	expiry: number,
}

export type DataStoreRecord = {
	version: number,
	file: File,
	orphanedFiles: {},
}

export type OrphanedFileQueueItem = {
	key: string,
	file: File,
	beingProcessed: boolean,
}

export type OrphanedFileQueueImpl = {
	__index: OrphanedFileQueueImpl,
	new: () -> OrphanedFileQueue,
	markFile: (self: OrphanedFileQueue, key: string, file: File) -> (),
	markFiles: (self: OrphanedFileQueue, key: string, files: { File }) -> (),
	_processQueueItems: (self: OrphanedFileQueue) -> (),
}

type OrphanedFileQueueProps = {
	queue: { OrphanedFileQueueItem },
	processQueueItem: ((item: OrphanedFileQueueItem) -> boolean)?,
}

export type OrphanedFileQueue = typeof(setmetatable({} :: OrphanedFileQueueProps, {} :: OrphanedFileQueueImpl))

export type StoreContext<T> = {
	name: string,
	template: T,
	schema: (value: any) -> (boolean, string?),

	migrations: { [number]: (value: any) -> any },
	importLegacyData: ((key: string) -> any?)?,
	latestVersion: number,

	dataStoreInterface: DataStoreInterface,
	hashMapInterface: HashMapInterface,

	orphanedFileQueue: OrphanedFileQueue,
	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () -> () },
	logger: Logger,
	onLockLost: ((key: string) -> ())?,

	recordScope: string,
	shardScope: string,
	txScope: string,
	lockScope: string,
}

local txInfoCheck = t.some(
	t.strictInterface({ committedData = t.any }),
	t.strictInterface({ committedData = t.any, txId = t.string, txData = t.any })
)
local fileCheck = t.some(t.strictInterface({ data = t.any }), t.strictInterface({ shard = t.string, count = t.number }))

export type LogMessage = {
	message: string,
	level: Level,
	context: { [string]: any }?,
}

export type Level = "fatal" | "error" | "warn" | "info" | "debug" | "trace"

export type LoggerImpl = {
	__index: LoggerImpl,

	log: (self: Logger, level: Level, message: string, context: { [string]: any }?) -> (),
	extend: (self: Logger, context: { [string]: any }) -> Logger,
}

export type LoggerProps = {
	_logCallback: (logMessage: LogMessage) -> (),
	_context: { [string]: any },
}

export type Logger = typeof(setmetatable({} :: LoggerProps, {} :: LoggerImpl))

export type RetryHandle<T> = {
	promise: T,
	cancel: () -> (),
}

export type HashMapInterfaceImpl = {
	__index: HashMapInterfaceImpl,
	_getHashMap: (self: HashMapInterface, scope: string) -> MemoryStoreHashMap,
	_retry: (self: HashMapInterface, func: () -> any) -> RetryHandle<Promise.TypedPromise<any>>,
	new: (memoryStoreService: MemoryStoreService) -> HashMapInterface,
	get: (self: HashMapInterface, scope: string, key: string) -> RetryHandle<Promise.TypedPromise<any?>>,
	set: (
		self: HashMapInterface,
		scope: string,
		key: string,
		value: any,
		expiration: number
	) -> RetryHandle<Promise.TypedPromise<boolean>>,
	update: (
		self: HashMapInterface,
		scope: string,
		key: string,
		transformFunction: (currentValue: any?) -> any?,
		expiration: number
	) -> RetryHandle<Promise.TypedPromise<any?>>,
	remove: (self: HashMapInterface, scope: string, key: string) -> RetryHandle<Promise.Promise>,
}

export type HashMapInterfaceProps = {
	_memoryStoreService: MemoryStoreService,
	_hashMaps: { [string]: MemoryStoreHashMap },
}

export type HashMapInterface = typeof(setmetatable({} :: HashMapInterfaceProps, {} :: HashMapInterfaceImpl))

export type DataStoreInterfaceImpl = {
	__index: DataStoreInterfaceImpl,
	_getDataStore: (self: DataStoreInterface, scope: string) -> GlobalDataStore,
	_retry: (self: DataStoreInterface, func: () -> any) -> Promise.TypedPromise<any>,
	new: (dataStoreService: DataStoreService) -> DataStoreInterface,
	getRequestBudgetForBudgetType: (self: DataStoreInterface, budgetType: Enum.DataStoreRequestType) -> number,
	get: (self: DataStoreInterface, scope: string, key: string) -> Promise.TypedPromise<(any?, DataStoreKeyInfo?)>,
	set: (
		self: DataStoreInterface,
		scope: string,
		key: string,
		value: any,
		userIds: { number }?,
		metadata: { [string]: any }?
	) -> Promise.TypedPromise<string>,
	update: (
		self: DataStoreInterface,
		scope: string,
		key: string,
		transformFunction: (
			currentValue: any,
			keyInfo: DataStoreKeyInfo
		) -> (any, { number }?, { [string]: any }?)
	) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
	remove: (self: DataStoreInterface, scope: string, key: string) -> Promise.TypedPromise<(any?, DataStoreKeyInfo?)>,
}

export type DataStoreInterfaceProps = {
	_dataStoreService: DataStoreService,
	_dataStores: { [string]: GlobalDataStore },
}

export type DataStoreInterface = typeof(setmetatable({} :: DataStoreInterfaceProps, {} :: DataStoreInterfaceImpl))

return {
	txInfoCheck = txInfoCheck,
	fileCheck = fileCheck,
}
