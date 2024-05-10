--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = require(script.Parent.Common)
local Promise = require(ReplicatedStorage.Packages.Promise)
local t = require(ReplicatedStorage.Packages.t)
local wrapPromiseFunc = require(ReplicatedStorage.Packages.Mix.wrapPromiseFunc)

local function createMockDataStoreKeyInfo()
	local currentTime = Common.getNow()
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
MockInterface._getScope = t.wrap(MockInterface._getScope, t.tuple(t.any, t.string))

function MockInterface:get(scope: string, key: string): Promise.TypedPromise<(any?, DataStoreKeyInfo?)>
	local info = self:_getScope(scope)[key]
	if info then
		return Promise.resolve(info.value, info.keyInfo)
	end
	return Promise.resolve(nil)
end
MockInterface.get = wrapPromiseFunc(
	MockInterface.get,
	t.tuple(t.any, t.string, t.string),
	t.tuple(t.optional(t.any), t.optional(Common.checkDataStoreKeyInfo))
)

function MockInterface:set(
	scope: string,
	key: string,
	value: any,
	userIds: { number }?,
	metadata: { [string]: any }?
): Promise.TypedPromise<string>
	local info = self:_getScope(scope)[key]
	if info == nil then
		info = {}
		info.keyInfo = createMockDataStoreKeyInfo()
		self:_getScope(scope)[key] = info
	end

	info.value = value
	info.keyInfo.UpdatedTime = Common.getNow()
	info.keyInfo.Version = HttpService:GenerateGUID(false)
	info.keyInfo._userIds = userIds or {}
	info.keyInfo._metadata = metadata or {}

	return Promise.resolve(info.keyInfo.Version)
end
MockInterface.set = wrapPromiseFunc(
	MockInterface.set,
	t.tuple(t.any, t.string, t.string, t.any, t.optional(Common.userIdsCheck), t.optional(Common.metadataCheck)),
	t.tuple(t.string)
)

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

	local newValue, newUserIds, newMetadata = transformFunction(info.value, info.keyInfo :: any)
	if newValue == nil then
		return Promise.resolve(info.value, info.keyInfo :: any)
	end

	info.value = newValue
	info.keyInfo.UpdatedTime = Common.getNow()
	info.keyInfo.Version = HttpService:GenerateGUID(false)
	if newUserIds then
		info.keyInfo._userIds = newUserIds
	end
	if newMetadata then
		info.keyInfo._metadata = newMetadata
	end

	return Promise.resolve(newValue, info.keyInfo :: any)
end
MockInterface.update = wrapPromiseFunc(
	MockInterface.update,
	t.tuple(t.any, t.string, t.string, Common.callableCheck),
	t.tuple(t.any, Common.checkDataStoreKeyInfo)
)

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
MockInterface.remove = wrapPromiseFunc(
	MockInterface.remove,
	t.tuple(t.any, t.string, t.string),
	t.tuple(t.optional(t.any), t.optional(Common.checkDataStoreKeyInfo))
)

return (MockInterface :: any) :: Common.DataStoreInterface
