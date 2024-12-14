local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local HashMapInterface = require(ReplicatedStorage.Packages.Lyra.HashMapInterface)
local MockHashMap = require(ReplicatedStorage.Packages.Lyra.MockHashMap)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("HashMapInterface", function()
	local mockService
	local hashMapInterface
	local mapName = "TestMap"

	beforeEach(function()
		jest.useFakeTimers()
		mockService = MockHashMap.createMockService()
		hashMapInterface = HashMapInterface.new(mockService)
	end)

	afterEach(function()
		jest.useRealTimers()
	end)

	it("should retry on TotalRequestsOverLimit error", function()
		local attempts = 0
		local mockHashMap = mockService:GetHashMap(mapName)
		mockHashMap.GetAsync = function()
			attempts += 1
			if attempts < 3 then
				error("TotalRequestsOverLimit", 0)
			end
			return "success"
		end

		local handle = hashMapInterface:get(mapName, "key")
		jest.runAllTimers()

		expect(attempts).toBe(3)
		return expect(handle.promise).resolves.toBe("success")
	end)

	it("should retry with exponential backoff", function()
		local attempts = 0
		local timestamps = {}
		local mockHashMap = mockService:GetHashMap(mapName)
		mockHashMap.GetAsync = function()
			attempts += 1
			table.insert(timestamps, DateTime.now().UnixTimestamp)
			if attempts < 3 then
				error("InternalError", 0)
			end
			return "success"
		end

		hashMapInterface:get(mapName, "key")
		jest.runAllTimers()

		expect(attempts).toBe(3)
		return expect(timestamps[3] - timestamps[2]).toBeGreaterThan(timestamps[2] - timestamps[1])
	end)

	it("should not retry on non-retryable errors", function()
		local attempts = 0
		local mockHashMap = mockService:GetHashMap(mapName)
		mockHashMap.GetAsync = function()
			attempts += 1
			error("InvalidKey", 0)
		end

		local handle = hashMapInterface:get(mapName, "key")
		jest.runAllTimers()

		expect(attempts).toBe(1)
		return expect(handle.promise).rejects.toMatch("InvalidKey")
	end)

	it("should cancel ongoing operation", function()
		local mockHashMap = mockService:GetHashMap(mapName)
		mockHashMap.GetAsync = function()
			error("TotalRequestsOverLimit", 0)
		end

		local handle = hashMapInterface:get(mapName, "key")
		handle.cancel()
		jest.runAllTimers()

		return expect(handle.promise).rejects.toMatch("HashMap error: operation cancelled")
	end)

	it("should prevent further retries after cancellation", function()
		local attempts = 0
		local mockHashMap = mockService:GetHashMap(mapName)
		mockHashMap.GetAsync = function()
			attempts += 1
			error("TotalRequestsOverLimit", 0)
		end

		local handle = hashMapInterface:get(mapName, "key")
		handle.promise:catch(function() end)
		handle.cancel()
		jest.runAllTimers()

		expect(attempts).toBe(1)
	end)

	it("should cache and reuse HashMaps for the same scope", function()
		local createCount = 0
		local originalGetHashMap = mockService.GetHashMap
		mockService.GetHashMap = function(self, name)
			createCount += 1
			return originalGetHashMap(self, name)
		end

		hashMapInterface:get(mapName, "key1")
		hashMapInterface:get(mapName, "key2")
		hashMapInterface:get("DifferentMap", "key3")

		expect(createCount).toBe(2)
	end)

	it("should propagate errors", function()
		local mockHashMap = mockService:GetHashMap(mapName)
		mockHashMap.GetAsync = function()
			error("TestError", 0)
		end

		local handle = hashMapInterface:get(mapName, "key")
		jest.runAllTimers()

		return expect(handle.promise).rejects.toMatch("TestError")
	end)
end)
