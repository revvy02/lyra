local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local DataStoreInterface = require(ReplicatedStorage.Packages.Lyra.DataStoreInterface)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("DataStoreInterface", function()
	local mockDataStoreService
	local dataStoreInterface

	beforeEach(function()
		mockDataStoreService = MockDataStoreService.new()
		dataStoreInterface = DataStoreInterface.new(mockDataStoreService)
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.useRealTimers()
	end)

	it("should retry on retryable error codes", function()
		local scope = "retryScope"
		local key = "retryKey"
		local value = { test = true }
		local attempts = 0

		local store = mockDataStoreService:GetDataStore(scope)
		local originalSetAsync = store.SetAsync
		store.SetAsync = function(self, ...)
			attempts += 1
			if attempts <= 2 then
				error("503: Service Unavailable", 0)
			end
			return originalSetAsync(self, ...)
		end

		dataStoreInterface:set(scope, key, value)
		jest.runAllTimers()

		expect(attempts).toBe(3)
		return expect(dataStoreInterface:get(scope, key)).resolves.toEqual(value)
	end)

	it("should fail after max retries", function()
		local scope = "maxRetryScope"
		local key = "maxRetryKey"
		local value = { test = true }

		local store = mockDataStoreService:GetDataStore(scope)
		store.SetAsync = function()
			error("503: Service Unavailable", 0)
		end

		local promise = dataStoreInterface:set(scope, key, value)
		jest.runAllTimers()

		return expect(promise).rejects.toMatch("too many retries")
	end)

	it("should not retry on non-retryable error codes", function()
		local scope = "nonRetryScope"
		local key = "nonRetryKey"
		local value = { test = true }
		local attempts = 0

		local store = mockDataStoreService:GetDataStore(scope)
		store.SetAsync = function()
			attempts += 1
			error("400: Bad Request", 0)
		end

		local promise = dataStoreInterface:set(scope, key, value)
		jest.runAllTimers()

		expect(attempts).toBe(1)
		return expect(promise).rejects.toMatch("DataStore error: 400: Bad Request")
	end)

	it("should wrap successful operations in promises", function()
		local scope = "promiseScope"
		local key = "promiseKey"
		local value = { test = true }

		local setPromise = dataStoreInterface:set(scope, key, value)
		jest.runAllTimers()

		expect(typeof(setPromise.expect)).toBe("function")

		local getPromise = dataStoreInterface:get(scope, key)
		jest.runAllTimers()

		expect(typeof(getPromise.expect)).toBe("function")
		return expect(getPromise).resolves.toEqual(value)
	end)

	it("should reject promise on errors", function()
		local scope = "errorScope"
		local key = "errorKey"

		local store = mockDataStoreService:GetDataStore(scope)
		store.GetAsync = function()
			error("Test error", 0)
		end

		local promise = dataStoreInterface:get(scope, key)
		jest.runAllTimers()

		expect(promise).rejects.toMatch("DataStore error: Test error")
	end)

	it("should return budget for request type", function()
		local budget = dataStoreInterface:getRequestBudgetForBudgetType(Enum.DataStoreRequestType.GetAsync)
		expect(typeof(budget)).toBe("number")
	end)
end)
