--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = require(script.Parent.Common)
local Promise = require(ReplicatedStorage.Packages.Promise)
local t = require(ReplicatedStorage.Packages.t)

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

type MockInterfaceConfig = {
	yields: boolean?,
}

local MockInterface = {}
MockInterface.__index = MockInterface

function MockInterface.new(config: MockInterfaceConfig?)
	local self = setmetatable({
		_store = {},
		_yields = if config then config.yields else nil,
	}, MockInterface)
	return self
end

function MockInterface:_wait(): Promise.Promise
	if self._yields then
		return Promise.new(function(resolve)
			task.delay(0.1, resolve)
		end)
	end
	return Promise.resolve()
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

function MockInterface:getRequestBudgetForBudgetType(_budgetType: Enum.DataStoreRequestType): number
	return 999
end
MockInterface.getRequestBudgetForBudgetType =
	t.wrap(MockInterface.getRequestBudgetForBudgetType, t.tuple(t.any, t.enum(Enum.DataStoreRequestType)))

function MockInterface:get(scope: string, key: string): Promise.TypedPromise<(any?, DataStoreKeyInfo?)>
	return self:_wait():andThen(function()
		local info = self:_getScope(scope)[key]
		if info then
			return info.value, info.keyInfo
		end
		return nil, nil
	end)
end
MockInterface.get = t.wrap(MockInterface.get, t.tuple(t.any, t.string, t.string))

function MockInterface:set(
	scope: string,
	key: string,
	value: any,
	userIds: { number }?,
	metadata: { [string]: any }?
): Promise.TypedPromise<string>
	return self:_wait():andThen(function()
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

		return info.keyInfo.Version
	end)
end
MockInterface.set = t.wrap(
	MockInterface.set,
	t.tuple(t.any, t.string, t.string, t.any, t.optional(Common.userIdsCheck), t.optional(Common.metadataCheck))
)

function MockInterface:update(
	scope: string,
	key: string,
	transformFunction: (
		currentValue: any,
		keyInfo: DataStoreKeyInfo
	) -> (any, { number }?, { [string]: any }?)
): Promise.TypedPromise<(any, DataStoreKeyInfo)>
	return self:_wait():andThen(function()
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
			return info.value, info.keyInfo :: any
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

		return newValue, info.keyInfo :: any
	end)
end
MockInterface.update = t.wrap(MockInterface.update, t.tuple(t.any, t.string, t.string, Common.callableCheck))

function MockInterface:remove(scope: string, key: string): Promise.TypedPromise<(any?, DataStoreKeyInfo?)>
	return self:_wait():andThen(function()
		local scopeData = self:_getScope(scope)
		local info = scopeData[key]
		if not info then
			return Promise.resolve(nil, nil)
		end

		local value, keyInfo = info.value, info.keyInfo
		scopeData[key] = nil

		return value, keyInfo
	end)
end
MockInterface.remove = t.wrap(MockInterface.remove, t.tuple(t.any, t.string, t.string))

return MockInterface
