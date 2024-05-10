--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)

type DataStoreInterface = {
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

local function getNow()
	return DateTime.now().UnixTimestampMillis / 1000
end

local function createMockDataStoreKeyInfo()
	local currentTime = getNow()
	local self
	self = {
		_metadata = {},
		_userIds = {},
		CreatedTime = currentTime,
		UpdatedTime = currentTime,
		Version = HttpService:GenerateGUID(false),
		GetMetadata = function()
			return self._metadata
		end,
		GetUserIds = function()
			return self._userIds
		end,
	}
	return self
end

local MockInterface = {}
MockInterface.__index = MockInterface

function MockInterface.new()
	local self = setmetatable({
		_store = {},
	}, MockInterface)
	return self
end

function MockInterface:_getScope(scope: string)
	local scopeData = self._store[scope]
	if scopeData == nil then
		scopeData = {}
		self._store[scope] = scopeData
	end

	return scopeData
end

function MockInterface:get(scope: string, key: string): Promise.TypedPromise<(any?, DataStoreKeyInfo?)>
	local info = self:_getScope(scope)[key]
	if info then
		return Promise.resolve(info.value, info.keyInfo)
	end
	return Promise.resolve(nil)
end

function MockInterface:set(
	scope: string,
	key: string,
	value: any,
	userIds: { number }?,
	options: DataStoreSetOptions?
): Promise.TypedPromise<string>
	local info = self:_getScope(scope)[key]
	if info == nil then
		info = {}
		info.keyInfo = createMockDataStoreKeyInfo()
		self:_getScope(scope)[key] = info
	end

	info.value = value
	info.keyInfo.UpdatedTime = getNow()
	info.keyInfo.Version = HttpService:GenerateGUID(false)
	info.keyInfo._userIds = userIds or {}
	info.keyInfo._metadata = options and options:GetMetadata() or {}

	return Promise.resolve(info.keyInfo.Version)
end

function MockInterface:update(
	scope: string,
	key: string,
	transformFunction: (
		currentValue: any,
		keyInfo: DataStoreKeyInfo
	) -> (any, { number }?, { [string]: any }?)
): Promise.TypedPromise<(any, DataStoreKeyInfo)>
	local scopeData = self:_getScope(scope)
	local info = scopeData[key]
	if not info then
		info = {
			value = nil,
			keyInfo = createMockDataStoreKeyInfo(),
		}
		scopeData[key] = info
	end

	local newValue, newUserIds, newMetadata = transformFunction(info.value, info.keyInfo)
	if newValue == nil then
		return Promise.resolve(info.value, info.keyInfo)
	end

	info.value = newValue
	info.keyInfo.UpdatedTime = getNow()
	info.keyInfo.Version = HttpService:GenerateGUID(false)
	if newUserIds then
		info.keyInfo._userIds = newUserIds
	end
	if newMetadata then
		info.keyInfo._metadata = newMetadata
	end

	return Promise.resolve(newValue, info.keyInfo)
end

function MockInterface:remove(scope: string, key: string): Promise.TypedPromise<(any?, DataStoreKeyInfo?)>
	local scopeData = self:_getScope(scope)
	local info = scopeData[key]
	if not info then
		return Promise.resolve(nil, nil)
	end

	local value, keyInfo = info.value, info.keyInfo
	scopeData[key] = nil

	return Promise.resolve(value, keyInfo)
end

return MockInterface
