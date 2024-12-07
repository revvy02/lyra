local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockHashMap = require(ReplicatedStorage.Packages.Lyra.MockHashMap)
local Promise = require(ReplicatedStorage.Packages.Promise)

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

describe("MockHashMap", function()
	local mockService
	local hashMap

	beforeAll(function()
		jest.useFakeTimers()
	end)

	beforeEach(function()
		mockService = MockHashMap.createMockService()
		hashMap = mockService:GetHashMap("test")
	end)

	describe("key validation", function()
		it("should reject empty keys", function()
			expect(function()
				call(hashMap, "SetAsync", "", "value", 30)
			end).toThrow("InvalidRequest: key cannot be empty")
		end)

		it("should reject keys longer than 128 characters", function()
			local longKey = string.rep("a", 129)
			expect(function()
				call(hashMap, "SetAsync", longKey, "value", 30)
			end).toThrow("InvalidRequest: key length exceeds limit")
		end)
	end)

	describe("value validation", function()
		it("should reject values that exceed 32KB", function()
			local largeValue = string.rep("a", 33 * 1024)
			expect(function()
				call(hashMap, "SetAsync", "key", largeValue, 30)
			end).toThrow("ItemValueSizeTooLarge")
		end)

		it.only("should reject values that can't be JSON encoded", function()
			local fn = function() end
			local ret = call(hashMap, "SetAsync", "key", fn, 30)
			expect(ret).toBe(false)
		end)
	end)

	describe("expiration validation", function()
		it("should reject non-positive expiration times", function()
			expect(function()
				call(hashMap, "SetAsync", "key", "value", 0)
			end).toThrow("InvalidRequest: expiration must be greater than 0")
		end)

		it("should reject expiration times over 45 days", function()
			expect(function()
				call(hashMap, "SetAsync", "key", "value", 3888001)
			end).toThrow("InvalidRequest: expiration exceeds maximum")
		end)
	end)

	describe("basic operations", function()
		it("should set and get values", function()
			call(hashMap, "SetAsync", "key", "value", 30)
			local value = call(hashMap, "GetAsync", "key")
			expect(value).toBe("value")
		end)

		it("should return nil for non-existent keys", function()
			local value = call(hashMap, "GetAsync", "nonexistent")
			expect(value).toBeNil()
		end)

		it("should remove values", function()
			call(hashMap, "SetAsync", "key", "value", 30)
			call(hashMap, "RemoveAsync", "key")
			local value = call(hashMap, "GetAsync", "key")
			expect(value).toBeNil()
		end)

		it.failing("should handle expiration", function()
			call(hashMap, "SetAsync", "key", "value", 1)
			jest.advanceTimersByTime(1100) -- 1.1 seconds
			local value = call(hashMap, "GetAsync", "key")
			expect(value).toBeNil()
		end)
	end)

	describe("update operations", function()
		it.failing("should update existing values", function()
			call(hashMap, "SetAsync", "key", { count = 1 }, 30)
			call(hashMap, "UpdateAsync", "key", function(val)
				val.count += 1
				return val
			end, 30)
			local value = call(hashMap, "GetAsync", "key")
			expect(value.count).toBe(2)
		end)

		it("should handle nil transform results", function()
			call(hashMap, "SetAsync", "key", "value", 30)
			call(hashMap, "UpdateAsync", "key", function()
				return nil
			end, 30)
			local value = call(hashMap, "GetAsync", "key")
			expect(value).toBeNil()
		end)

		it("should handle transform errors", function()
			call(hashMap, "SetAsync", "key", "value", 30)
			expect(function()
				call(hashMap, "UpdateAsync", "key", function()
					error("transform error")
				end, 30)
			end).toThrow("TransformCallbackFailed")
		end)

		it.failing("should retry on concurrent updates", function()
			call(hashMap, "SetAsync", "key", "initial", 30)

			-- Simulate concurrent updates by modifying the value between transform check and set
			local updateCount = 0
			local success, err = pcall(function()
				call(hashMap, "UpdateAsync", "key", function(value)
					if updateCount == 0 then
						updateCount += 1
						call(hashMap, "SetAsync", "key", "modified", 30)
					end
					return "new value"
				end, 30)
			end)

			-- Should have attempted retries with exponential backoff
			jest.advanceTimersByTime(2000) -- 2^1 seconds
			jest.advanceTimersByTime(4000) -- 2^2 seconds
			jest.advanceTimersByTime(8000) -- 2^3 seconds

			expect(success).toBe(false)
			expect(err:match("DataUpdateConflict")).toBeTruthy()
		end)
	end)

	describe("rate limiting", function()
		it.failing("should enforce rate limits", function()
			-- Make 101 rapid requests (base rate limit is 100)
			expect(function()
				for i = 1, 101 do
					if i == 101 then
						call(hashMap, "GetAsync", "key")
					else
						pcall(function()
							call(hashMap, "GetAsync", "key")
						end)
					end
				end
			end).toThrow("TotalRequestsOverLimit")
		end)
	end)

	describe("multiple hash maps", function()
		it("should maintain separate data for different maps", function()
			local hashMap2 = mockService:GetHashMap("test2")

			call(hashMap, "SetAsync", "key", "value1", 30)
			call(hashMap2, "SetAsync", "key", "value2", 30)

			local value1 = call(hashMap, "GetAsync", "key")
			local value2 = call(hashMap2, "GetAsync", "key")

			expect(value1).toBe("value1")
			expect(value2).toBe("value2")
		end)
	end)
end)
