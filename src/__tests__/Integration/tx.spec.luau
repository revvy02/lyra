local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockHashMap = require(ReplicatedStorage.Packages.Lyra.MockHashMap)
local Store = require(script.Parent.Parent.Parent.Store)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("tx", function()
	local store
	local mockData
	local mockMemory

	local function resetStore()
		store = Store.createStore({
			name = "tx tests",
			template = { coins = 0 },
			schema = function(data)
				return typeof(data.coins) == "number", "Invalid data format"
			end,
		})
		store._ctx.dataStoreInterface._dataStoreService = mockData
		store._ctx.hashMapInterface._memoryStoreService = mockMemory
	end

	local function crash()
		local snap = MockDataStoreService.snapshot(mockData)
		store:close()
		for _ = 1, 5 do
			jest.advanceTimersByTime(1000)
		end
		MockDataStoreService.restore(mockData, snap)
	end

	beforeEach(function()
		jest.useFakeTimers()

		mockData = MockDataStoreService.createMockService()
		mockMemory = MockHashMap.createMockService()
		resetStore()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	it("crash before commit should result in abort", function()
		store:load("key1")
		store:load("key2")

		jest.advanceTimersByTime(1000)

		local key2Set = false
		local setMock, realSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
		setMock.mockImplementation(function(self, key, ...)
			if key == "key1" then
				local ret = table.pack(realSet(self, key, ...))
				key2Set = true
				return table.unpack(ret)
			end
			return realSet(self, key, ...)
		end)

		store:tx({ "key1", "key2" }, function(state)
			state.key1.coins += 10
			state.key2.coins += 10
			return true
		end)

		while key2Set == false do
			jest.advanceTimersByTime(1)
		end

		crash()
		resetStore()

		store:load("key1")
		jest.advanceTimersByTime(1000)

		local key1Data = store:get("key1")
		jest.advanceTimersByTime(1000)

		return expect(key1Data).resolves.toEqual({ coins = 0 })
	end)
end)
