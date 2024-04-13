export type DataStoreInterface = {
	get: (self: any, key: string) -> (any, DataStoreKeyInfo),
	set: (self: any, key: string, value: any, userIds: { number }?, options: DataStoreSetOptions?) -> string,
	update: (
		self: any,
		key: string,
		transformFunction: (currentValue: any, keyInfo: DataStoreKeyInfo) -> (any, { number }?, { [string]: any }?)
	) -> (any, DataStoreKeyInfo),
	remove: (self: any, key: string) -> (any, DataStoreKeyInfo),
}

return nil
