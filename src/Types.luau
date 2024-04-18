local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)

export type DataStoreInterface = {
	get: (self: any, storeName: string, key: string) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
	set: (
		self: any,
		storeName: string,
		key: string,
		value: any,
		userIds: { number }?,
		options: DataStoreSetOptions?
	) -> Promise.TypedPromise<string>,
	update: (
		self: any,
		storeName: string,
		key: string,
		transformFunction: (currentValue: any, keyInfo: DataStoreKeyInfo) -> (any, { number }?, { [string]: any }?)
	) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
	remove: (self: any, storeName: string, key: string) -> Promise.TypedPromise<(any, DataStoreKeyInfo)>,
}

export type DataChunk = {
	data: any,
} & {
	shard: string,
	count: number,
}

export type DataSection = {
	committed_data: DataChunk,
	tx_data: DataChunk?,
}

export type MetadataSection = {
	lock_id: string?,
	lock_expiry: number?,
	tx_id: string?,
}

export type DataStoreRecord = {
	_metadata: MetadataSection,
	data: DataSection,
}

return nil
