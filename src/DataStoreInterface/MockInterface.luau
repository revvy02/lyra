-- TODO: tests
-- TODO: mock DataStoreService V2 features - userids, datastoreoptions, etc.

local MockInterface = {}
MockInterface.__index = MockInterface

function MockInterface.new()
	local self = setmetatable({
		_store = {},
	}, MockInterface)
	return self
end

function MockInterface:get(key: any): any
	return self._store[key]
end

function MockInterface:set(key: any, value: any)
	self._store[key] = value
end

function MockInterface:update(key: any, callback: (value: any) -> any)
	local result = callback(self._store[key])
	if result == nil then
		return
	end

	self._store[key] = result
end

return MockInterface
