--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local t = require(ReplicatedStorage.Packages.t)

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

local metadataCheck = t.map(t.string, t.any)
local userIdsCheck = t.array(t.number)

local function callableCheck(value: any): (boolean, string?)
	if t.callback(value) then
		return true
	end

	local ok, err = t.table(value)
	if not ok then
		return false, err
	end

	local mt = getmetatable(value)
	if mt == nil then
		return false, "expected a mock object"
	end

	if mt.__call == nil then
		return false, "expected a mock object"
	end

	return true
end

local function checkDataStoreKeyInfo(keyInfo: any): (boolean, string?)
	if typeof(keyInfo) ~= "table" and (typeof(keyInfo) ~= "Instance" or not keyInfo:IsA("DataStoreKeyInfo")) then
		return false, "expected a DataStoreKeyInfo instance"
	end

	if typeof(keyInfo) == "table" then
		if keyInfo._metadata == nil or keyInfo._userIds == nil then
			return false, "expected a DataStoreKeyInfo instance"
		end
	end

	return true
end

local function getNow()
	return DateTime.now().UnixTimestampMillis / 1000
end

return {
	metadataCheck = metadataCheck,
	userIdsCheck = userIdsCheck,
	callableCheck = callableCheck,
	checkDataStoreKeyInfo = checkDataStoreKeyInfo,
	getNow = getNow,
}
