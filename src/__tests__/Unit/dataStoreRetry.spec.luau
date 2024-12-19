local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local dataStoreRetry = require(ReplicatedStorage.Packages.Lyra.dataStoreRetry)

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("dataStoreRetry", function()
	local mockData
	local store

	beforeEach(function()
		mockData = MockDataStoreService.new()
		store = mockData:GetDataStore("dataStoreRetry test")
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.useRealTimers()
	end)

	it("should retry on retryable error codes", function()
		local key = "retryKey"
		local value = { test = true }
		local attempts = 0

		local setMock, realSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
		setMock.mockImplementation(function(self, ...)
			attempts += 1
			if attempts <= 2 then
				error("503: Service Unavailable", 0)
			end
			return realSet(self, ...)
		end)

		dataStoreRetry(function()
			return store:SetAsync(key, value)
		end)
		jest.runAllTimers()

		expect(attempts).toBe(3)

		local val = store:GetAsync(key)
		jest.runAllTimers()

		return expect(val).toEqual(value)
	end)

	it("should fail after max retries", function()
		local key = "maxRetryKey"
		local value = { test = true }

		MockDataStoreService.queueError(mockData, "SetAsync", "503: Service Unavailable", 6)

		local p = dataStoreRetry(function()
			return store:SetAsync(key, value)
		end)
		jest.runAllTimers()

		return expect(p).rejects.toMatch("too many retries")
	end)

	it("should not retry on non-retryable error codes", function()
		local key = "nonRetryKey"
		local value = { test = true }

		MockDataStoreService.queueError(mockData, "SetAsync", "400: Bad Request")

		local p = dataStoreRetry(function()
			return store:SetAsync(key, value)
		end)
		jest.runAllTimers()

		return expect(p).rejects.toMatch("400: Bad Request")
	end)
end)
