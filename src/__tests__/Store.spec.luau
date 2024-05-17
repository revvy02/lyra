local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Promise = require(ReplicatedStorage.Packages.Promise)

local it = JestGlobals.it
local expect = JestGlobals.expect
local describe = JestGlobals.describe
local beforeEach = JestGlobals.beforeEach
local jest = JestGlobals.jest

jest.useFakeTimers()

describe("Store Transaction Race Conditions", function()
	local store
	local schema = function(value)
		return type(value) == "table"
	end

	beforeEach(function()
		local MockInterface = require(ReplicatedStorage.Packages.Mix.DataStoreInterface.MockInterface)
		local createStore = require(ReplicatedStorage.Packages.Mix.Store).createStore
		store = createStore({
			name = "TestStore",
			template = {},
			schema = schema,
			dataStoreInterface = MockInterface.new({ yields = true }),
		})
	end)

	it("should handle concurrent writes to the same key", function()
		local tx1 = store:lock("testKey"):andThen(function()
			return store:tx({ "testKey" }, function(state)
				state.testKey.someData = "tx1"
				return state
			end)
		end)

		local tx2 = store:lock("testKey"):andThen(function()
			return store:tx({ "testKey" }, function(state)
				state.testKey.someData = "tx2"
				return state
			end)
		end)

		jest.runAllTimers()

		return Promise.all({ tx1, tx2 })
			:andThen(function()
				local finalState = store._cache["testKey"].someData
				expect(finalState == "tx1" or finalState == "tx2").toBe(true)
			end)
			:catch(error)
	end)

	it("should handle sequential transaction dependencies", function()
		local tx1 = store:lock("testKey"):andThen(function()
			return store:tx({ "testKey" }, function(state)
				state.testKey.someData = "tx1"
				return state
			end)
		end)

		jest.runAllTimers()

		return tx1:andThen(function()
			local tx2 = store:tx({ "testKey" }, function(state)
				state.testKey.someData = state.testKey.someData .. "tx2"
				return state
			end)

			jest.runAllTimers()

			return tx2:andThen(function()
				expect(store._cache["testKey"].someData).toBe("tx1tx2")
			end)
		end):catch(error)
	end)

	it("should handle cross-key dependencies", function()
		local tx1 = store
			:lock("testKey1")
			:andThen(function()
				return store:lock("testKey2")
			end)
			:andThen(function()
				return store:tx({ "testKey1", "testKey2" }, function(state)
					state.testKey1.someData = "tx1"
					state.testKey2.someData = "tx1"
					return state
				end)
			end)

		jest.runAllTimers()

		return tx1:andThen(function()
			local tx2 = store:tx({ "testKey1", "testKey2" }, function(state)
				state.testKey1.someData ..= "tx2"
				state.testKey2.someData ..= "tx2"
				return state
			end)

			jest.runAllTimers()

			return tx2:andThen(function()
				expect(store._cache["testKey1"].someData).toBe("tx1tx2")
				expect(store._cache["testKey2"].someData).toBe("tx1tx2")
			end)
		end):catch(error)
	end)

	it("should handle simultaneous lock and unlock operations", function()
		local p = store
			:lock("testKey")
			:andThen(function()
				return store:unlock("testKey")
			end)
			:catch(error)

		jest.runAllTimers()

		return p:andThen(function()
			expect(store._cache["testKey"]).toBe(nil)
		end)
	end)

	it("should handle transaction overlaps", function()
		local locks = Promise.all({
			store:lock("testKey1"),
			store:lock("testKey2"),
			store:lock("testKey3"),
		})

		local tx1 = locks:andThen(function()
			return store:tx({ "testKey1", "testKey2" }, function(state)
				state.testKey1.someData = "tx1"
				state.testKey2.someData = "tx1"
				return state
			end)
		end)

		local tx2 = locks:andThen(function()
			return store:tx({ "testKey2", "testKey3" }, function(state)
				state.testKey2.someData ..= "tx2"
				state.testKey3.someData = "tx2"
				return state
			end)
		end)

		jest.runAllTimers()

		return Promise.all({ tx1, tx2 })
			:andThen(function()
				expect(store._cache["testKey1"].someData).toBe("tx1")
				expect(store._cache["testKey2"].someData).toBe("tx1tx2")
				expect(store._cache["testKey3"].someData).toBe("tx2")
			end)
			:catch(error)
	end)

	it("should not allow yielding in transaction callbacks", function()
		local p = store:lock("testKey"):andThen(function()
			return store:tx({ "testKey" }, function(state)
				coroutine.yield()
				state.testKey.someData = "invalid"
				return state
			end)
		end)

		jest.runAllTimers()

		return expect(function()
			return p:expect()
		end).toThrow("attempt to yield")
	end)
end)
