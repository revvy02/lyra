-- TODO: tests
-- TODO: mock DataStoreService V2 features - userids, datastoreoptions, etc.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)

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

function MockInterface:get(scope: string, key: any)
	return Promise.resolve(self:_getScope(scope)[key])
end

function MockInterface:set(scope: string, key: any, value: any)
	self:_getScope(scope)[key] = value
	return Promise.resolve()
end

function MockInterface:update(scope: string, key: any, callback: (value: any) -> any)
	local result = callback(self:_getScope(scope)[key])
	if result == nil then
		return Promise.resolve(self:_getScope(scope)[key])
	end

	self:_getScope(scope)[key] = result

	return Promise.resolve(result)
end

function MockInterface:remove(scope: string, key: any)
	self:_getScope(scope)[key] = nil
	return Promise.resolve()
end

return MockInterface
