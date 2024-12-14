local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Promise = require(ReplicatedStorage.Packages.Promise)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local beforeAll = JestGlobals.beforeAll
local jest = JestGlobals.jest

local function call<T>(obj: any, method: string, ...: any): T
	local args = table.pack(...)
	local result = Promise.try(function()
		return obj[method](obj, table.unpack(args))
	end)
	jest.runAllTimers()
	return result:expect()
end

describe("MockDataStoreService", function()
	local mockDataStoreService
	local dsName = "TestDataStore"
	local scope = "testScope"
	local dataStore

	beforeAll(function()
		jest.useFakeTimers()
	end)

	beforeEach(function()
		jest.useFakeTimers()
		mockDataStoreService = MockDataStoreService.createMockService()
		dataStore = mockDataStoreService:GetDataStore(dsName, scope)
	end)

	describe("Basic Functionality", function()
		it("should return a data store object", function()
			expect(dataStore).toBeDefined()
			expect(typeof(dataStore)).toBe("table")
		end)

		it("GetAsync should return nil for a non-existent key", function()
			local value = call(dataStore, "GetAsync", "nonExistentKey")
			expect(value).toBeNil()
		end)

		it("SetAsync and GetAsync should store and retrieve a value", function()
			local key = "testKey"
			local testValue = { foo = "bar" }

			local res = call(dataStore, "SetAsync", key, testValue)
			expect(res).toBeDefined()

			local retrieved = call(dataStore, "GetAsync", key)
			expect(retrieved).toEqual(testValue)
		end)

		it("SetAsync should overwrite an existing value", function()
			local key = "testKey"
			local firstValue = { count = 1 }
			local secondValue = { count = 2 }

			local res1 = call(dataStore, "SetAsync", key, firstValue)
			expect(res1).toBeDefined()

			local res2 = call(dataStore, "SetAsync", key, secondValue)
			expect(res2).toBeDefined()

			local retrieved = call(dataStore, "GetAsync", key)
			expect(retrieved).toEqual(secondValue)
		end)

		it("RemoveAsync should return old value and remove the key", function()
			local key = "removeKey"
			local value = { data = "toRemove" }

			local res = call(dataStore, "SetAsync", key, value)
			expect(res).toBeDefined()

			local oldValue = call(dataStore, "RemoveAsync", key)
			expect(oldValue).toEqual(value)

			local afterRemove = call(dataStore, "GetAsync", key)
			expect(afterRemove).toBeNil()
		end)

		it("UpdateAsync should update value using transform function", function()
			local key = "updateKey"
			local initialValue = { counter = 10 }
			call(dataStore, "SetAsync", key, initialValue)

			local function transform(currentValue)
				local newValue = { counter = currentValue.counter + 5 }
				return newValue
			end

			local newVal = call(dataStore, "UpdateAsync", key, transform)
			expect(newVal).toEqual({ counter = 15 })

			local afterUpdate = call(dataStore, "GetAsync", key)
			expect(afterUpdate).toEqual({ counter = 15 })
		end)

		it("UpdateAsync cancels update if transform returns nil", function()
			local key = "updateCancelKey"
			local initialValue = { score = 50 }
			call(dataStore, "SetAsync", key, initialValue)

			local function noUpdate(_currentValue)
				return nil
			end

			local attemptedVal = call(dataStore, "UpdateAsync", key, noUpdate)
			expect(attemptedVal).toEqual({ score = 50 })

			local afterUpdate = call(dataStore, "GetAsync", key)
			expect(afterUpdate).toEqual({ score = 50 })
		end)

		it("should handle transform errors", function()
			local key = "errorKey"
			local value = { data = 1 }
			call(dataStore, "SetAsync", key, value)

			expect(function()
				call(dataStore, "UpdateAsync", key, function()
					error("Transform error", 2)
				end)
			end).toThrow("Transform error")

			local after = call(dataStore, "GetAsync", key)
			expect(after).toEqual(value)
		end)
	end)

	describe("Versioning", function()
		it("should create only one version for multiple writes within the same hour", function()
			local key = "singleHourKey"
			call(dataStore, "SetAsync", key, { ver = 1 })
			call(dataStore, "SetAsync", key, { ver = 2 })

			local versionsPage = call(dataStore, "ListVersionsAsync", key)
			local versions = versionsPage:GetCurrentPage()
			expect(#versions).toBe(1)

			local currentVersion = versions[1]
			local val = call(dataStore, "GetVersionAsync", key, currentVersion.Version)
			expect(val).toEqual({ ver = 2 })
		end)

		it("should create a new version after time advances by an hour", function()
			local key = "multiHourKey"
			call(dataStore, "SetAsync", key, { ver = 1 })

			jest.advanceTimersByTime(3600000)

			call(dataStore, "SetAsync", key, { ver = 2 })

			local versionsPage = call(dataStore, "ListVersionsAsync", key)
			local versions = versionsPage:GetCurrentPage()

			expect(#versions).toBe(2)

			local latest = versions[#versions]
			local val = call(dataStore, "GetVersionAsync", key, latest.Version)
			expect(val).toEqual({ ver = 2 })
		end)
	end)

	describe("Rate Limiting / Queueing", function()
		it("should handle multiple calls without immediate error", function()
			for i = 1, 10 do
				call(dataStore, "SetAsync", "rateKey" .. i, { i = i })
			end
		end)

		it("should queue requests and process them after delays", function()
			for i = 1, 20 do
				call(dataStore, "GetAsync", "someKey" .. i)
			end
		end)

		it("should eventually hit TotalRequestsOverLimit with many calls", function()
			local numRequests = 31
			local done = false
			local finishedCount = 0

			jest.useRealTimers()
			for _ = 1, numRequests do
				task.spawn(function()
					local success, err = pcall(function()
						dataStore:GetAsync("spamKey")
					end)

					finishedCount += 1

					if not success and string.find(err, "request dropped") then
						done = true
					end
				end)
			end

			while not done and finishedCount < numRequests do
				task.wait()
			end

			expect(done).toBe(true)
		end)

		it("should process requests in queue order", function()
			local results = {}
			local values = {}

			for i = 1, 5 do
				values[i] = { data = i }
				call(dataStore, "SetAsync", "key" .. i, values[i])
			end

			for i = 1, 5 do
				task.spawn(function()
					results[i] = dataStore:GetAsync("key" .. i)
				end)
			end

			jest.runAllTimers()

			for i = 1, 5 do
				expect(results[i]).toEqual(values[i])
			end
		end)

		it("budget should change after calls", function()
			local budget1 = mockDataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync)

			task.spawn(dataStore.GetAsync, dataStore, "key1")
			task.spawn(dataStore.GetAsync, dataStore, "key2")

			local budget2 = mockDataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync)
			expect(budget2).never.toBe(budget1)

			task.spawn(dataStore.GetAsync, dataStore, "key3")
			task.spawn(dataStore.GetAsync, dataStore, "key4")

			local budget3 = mockDataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync)
			expect(budget3).never.toBe(budget2)
		end)
	end)

	describe("Snapshot / Restore", function()
		it("should capture and restore service state", function()
			call(dataStore, "SetAsync", "key1", { value = 1 })
			call(dataStore, "SetAsync", "key2", { value = 2 })

			local snapshot = MockDataStoreService.snapshot(mockDataStoreService)

			call(dataStore, "SetAsync", "key1", { value = 100 })
			call(dataStore, "RemoveAsync", "key2")
			call(dataStore, "SetAsync", "key3", { value = 3 })

			local key1Val = call(dataStore, "GetAsync", "key1")
			local key2Val = call(dataStore, "GetAsync", "key2")
			local key3Val = call(dataStore, "GetAsync", "key3")
			expect(key1Val).toEqual({ value = 100 })
			expect(key2Val).toBeNil()
			expect(key3Val).toEqual({ value = 3 })

			MockDataStoreService.restore(mockDataStoreService, snapshot)

			key1Val = call(dataStore, "GetAsync", "key1")
			key2Val = call(dataStore, "GetAsync", "key2")
			key3Val = call(dataStore, "GetAsync", "key3")
			expect(key1Val).toEqual({ value = 1 })
			expect(key2Val).toEqual({ value = 2 })
			expect(key3Val).toBeNil()
		end)

		it("should restore version history", function()
			local key = "versionKey"
			call(dataStore, "SetAsync", key, { ver = 1 })
			jest.advanceTimersByTime(3600000)
			call(dataStore, "SetAsync", key, { ver = 2 })

			local snapshot = MockDataStoreService.snapshot(mockDataStoreService)

			jest.advanceTimersByTime(3600000)
			call(dataStore, "SetAsync", key, { ver = 3 })

			local versionsPage = call(dataStore, "ListVersionsAsync", key)
			local versions = versionsPage:GetCurrentPage()
			expect(#versions).toBe(3)

			MockDataStoreService.restore(mockDataStoreService, snapshot)

			versionsPage = call(dataStore, "ListVersionsAsync", key)
			versions = versionsPage:GetCurrentPage()
			expect(#versions).toBe(2)

			local latest = versions[#versions]
			local val = call(dataStore, "GetVersionAsync", key, latest.Version)
			expect(val).toEqual({ ver = 2 })
		end)

		it("should restore cache state", function()
			call(dataStore, "SetAsync", "cacheKey", { cached = true })
			call(dataStore, "GetAsync", "cacheKey")

			local snapshot = MockDataStoreService.snapshot(mockDataStoreService)

			call(dataStore, "SetAsync", "cacheKey", { cached = false })
			call(dataStore, "GetAsync", "cacheKey")

			MockDataStoreService.restore(mockDataStoreService, snapshot)

			local value = call(dataStore, "GetAsync", "cacheKey")
			expect(value).toEqual({ cached = true })
		end)
	end)
end)
