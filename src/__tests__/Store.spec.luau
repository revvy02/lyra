local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Constants = require(ReplicatedStorage.Packages.Mix.Constants)
local DataStoreInterface = require(ReplicatedStorage.Packages.Mix.DataStoreInterface)
local Store = require(ReplicatedStorage.Packages.Mix.Store)

local it = JestGlobals.it
local expect = JestGlobals.expect

local function getStore()
	local mockInterface = DataStoreInterface.Mock.new()
	return Store.createStore({
		name = "test",
		template = {
			foo = "bar",
		},
		schema = function()
			return true
		end,
		dataStoreInterface = mockInterface,
	}),
		mockInterface
end

it("lock", function()
	local store, mockInterface = getStore()
	store:lock("123"):expect()
	local record = mockInterface._store[Constants.RECORD_SCOPE]["123"]
	expect(record).toHaveProperty("_metadata")
	expect(record._metadata).toHaveProperty("lock_id")
	expect(record._metadata).toHaveProperty("lock_expiry")
end)

it("unlock", function()
	local store, mockInterface = getStore()
	store:lock("123"):expect()
	store:unlock("123"):expect()
	local record = mockInterface._store[Constants.RECORD_SCOPE]["123"]
	expect(record).toHaveProperty("_metadata")
	expect(record._metadata).never.toHaveProperty("lock_id")
	expect(record._metadata).never.toHaveProperty("lock_expiry")
end)

it("update", function()
	local store, mockInterface = getStore()
	store:lock("123"):expect()
	store:update("123", function(state)
		state.foo = "baz"
		return state
	end)
	store:save("123"):expect()
	local record = mockInterface._store[Constants.RECORD_SCOPE]["123"]
	expect(record.data.foo).toBe("baz")
end)
