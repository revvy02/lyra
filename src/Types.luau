--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local t = require(ReplicatedStorage.Packages.t)

export type DataStoreInterface = {
	get: (self: DataStoreInterface, scope: string, key: string) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
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
		transformFunction: (currentValue: any, keyInfo: DataStoreKeyInfo) -> (any, { number }?, { [string]: any }?)?
	) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
	remove: (self: DataStoreInterface, scope: string, key: string) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
	getRequestBudgetForBudgetType: (self: DataStoreInterface, budgetType: Enum.DataStoreRequestType) -> number,
}

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

export type Lock = {
	id: string?,
	expiry: number?,
}

export type DataStoreRecord = {
	version: number,
	lock: Lock,
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

export type StoreContext = {
	name: string,
	template: { [string]: any },
	schema: (value: { [string]: any }) -> (boolean, string?),
	migrations: { [number]: (value: { [string]: any }) -> { [string]: any } },
	dataStoreInterface: DataStoreInterface,
	lockId: string,
	orphanedFileQueue: OrphanedFileQueue,
	latestVersion: number,
}

local txInfoCheck = t.some(
	t.strictInterface({ committedData = t.any }),
	t.strictInterface({ committedData = t.any, txId = t.string, txData = t.any })
)
local fileCheck = t.some(t.strictInterface({ data = t.any }), t.strictInterface({ shard = t.string, count = t.number }))

return {
	txInfoCheck = txInfoCheck,
	fileCheck = fileCheck,
}
