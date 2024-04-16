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

function MockInterface:get(key: any)
	return Promise.resolve(self._store[key])
end

function MockInterface:set(key: any, value: any)
	self._store[key] = value
	return Promise.resolve()
end

function MockInterface:update(key: any, callback: (value: any) -> any)
	local result = callback(self._store[key])
	if result == nil then
		return
	end

	self._store[key] = result

	return Promise.resolve()
end

function MockInterface:remove(key: any)
	self._store[key] = nil
	return Promise.resolve()
end

return MockInterface
