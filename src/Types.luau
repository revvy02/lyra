--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local t = require(ReplicatedStorage.Packages.t)

export type DataStoreInterface = {
	get: (self: DataStoreInterface, storeName: string, key: string) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
	set: (
		self: DataStoreInterface,
		storeName: string,
		key: string,
		value: any,
		userIds: { number }?,
		options: DataStoreSetOptions?
	) -> Promise.TypedPromise<string>,
	update: (
		self: DataStoreInterface,
		storeName: string,
		key: string,
		transformFunction: (currentValue: any, keyInfo: DataStoreKeyInfo) -> (any, { number }?, { [string]: any }?)
	) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
	remove: (self: DataStoreInterface, storeName: string, key: string) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
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
	lock: Lock,
	file: File,
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
