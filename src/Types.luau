--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataStoreInterface = require(script.Parent.DataStoreInterface)
local HashMapInterface = require(script.Parent.HashMapInterface)
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
	migrateFromOtherSystem: ((key: string) -> T?)?,
	latestVersion: number,

	dataStoreInterface: DataStoreInterface.DataStoreInterface,
	hashMapInterface: HashMapInterface.HashMapInterface,

	orphanedFileQueue: OrphanedFileQueue,
	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () -> () },
	log: (level: "fatal" | "error" | "warn" | "info" | "debug" | "trace", message: string) -> (),
	onLockLost: ((key: string) -> ())?,

	recordScope: string,
	shardScope: string,
	txScope: string,
	lockScope: string,
}

export type LogMessage = {
	message: string,
	level: "fatal" | "error" | "warn" | "info" | "debug" | "trace",
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
