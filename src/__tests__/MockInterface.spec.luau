local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockInterface = require(ReplicatedStorage.Packages.Mix.DataStoreInterface.MockInterface)
local Promise = require(ReplicatedStorage.Packages.Promise)

local jest = JestGlobals.jest
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach

describe("MockInterface", function()
	local key = "testKey"
	local scope = "testScope"
	local store

	beforeEach(function()
		store = MockInterface.new()
	end)

	it("sets, gets, updates, and removes a value correctly", function()
		local value = { data = "testData" }
		local updatedValue = { data = "updatedData" }

		return store
			:set(scope, key, value)
			:andThen(function()
				return store:get(scope, key)
			end)
			:andThen(function(result)
				expect(result).toEqual(value)
			end)
			:andThen(function()
				return store:update(scope, key, function()
					return updatedValue
				end)
			end)
			:andThen(function()
				return store:get(scope, key)
			end)
			:andThen(function(result)
				expect(result).toEqual(updatedValue)
			end)
			:andThen(function()
				return store:remove(scope, key)
			end)
			:andThen(function()
				return store:get(scope, key)
			end)
			:andThen(function(result)
				expect(result).toBeNil()
			end)
	end)

	it("handles non-existent keys gracefully", function()
		return store:get(scope, "nonExistentKey"):andThen(function(result)
			expect(result).toBeNil()
		end)
	end)

	it("supports various data types", function()
		local values = {
			["string"] = "a string",
			["number"] = 42,
			["table"] = { data = "tableData" },
			["boolean"] = true,
			["nil"] = nil,
		}

		local promises = {}

		for dataType, value in pairs(values) do
			table.insert(
				promises,
				store
					:set(scope, key .. dataType, value)
					:andThen(function()
						return store:get(scope, key .. dataType)
					end)
					:andThen(function(result)
						expect(result).toEqual(value)
					end)
			)
		end

		return Promise.all(promises)
	end)

	it("handles nested table structures", function()
		local complexValue = { data = { nested = { veryNested = { "value1", "value2" } } } }
		return store
			:set(scope, key, complexValue)
			:andThen(function()
				return store:get(scope, key)
			end)
			:andThen(function(result)
				expect(result).toEqual(complexValue)
			end)
	end)

	it("sets and gets userIds and metadata correctly", function()
		local value = { data = "userData" }
		local userIds = { 12345, 67890 }
		local metadata = { important = "yes" }

		return store
			:set(scope, key, value, userIds, metadata)
			:andThen(function()
				return store:get(scope, key)
			end)
			:andThen(function(_, keyInfo)
				expect(keyInfo:GetUserIds()).toEqual(userIds)
				expect(keyInfo:GetMetadata()).toEqual(metadata)
			end)
	end)

	it("preserves userIds and metadata on remove", function()
		local value = { data = "userData" }
		local userIds = { 12345 }
		local metadata = { deleted = "true" }

		return store
			:set(scope, key, value, userIds, metadata)
			:andThen(function()
				return store:remove(scope, key)
			end)
			:andThen(function(_, keyInfo)
				expect(keyInfo:GetUserIds()).toEqual(userIds)
				expect(keyInfo:GetMetadata()).toEqual(metadata)
			end)
	end)

	it("increments version on update", function()
		local value = { data = "initialData" }
		local updatedValue = { data = "updatedData" }

		return store
			:set(scope, key, value)
			:andThen(function()
				return store:get(scope, key)
			end)
			:andThen(function(_, keyInfo)
				local oldVersion = keyInfo.Version
				return store
					:update(scope, key, function()
						return updatedValue
					end)
					:andThen(function()
						return store:get(scope, key)
					end)
					:andThen(function(_, newKeyInfo)
						expect(newKeyInfo.Version).never.toBe(oldVersion)
					end)
			end)
	end)

	it("handles concurrent updates correctly", function()
		local initialValue = { count = 0 }
		local updateFunction = jest.fn(function(oldValue)
			return { count = oldValue.count + 1 }
		end)
		local updates = {}

		store:set(scope, key, initialValue):expect()

		for _ = 1, 10 do
			table.insert(updates, store:update(scope, key, updateFunction))
		end

		return Promise.all(updates)
			:andThen(function()
				return store:get(scope, key)
			end)
			:andThen(function(result)
				expect(result.count).toBe(10)
				expect(#updateFunction.mock.calls).toBe(10)
			end)
	end)

	it("throws an error for invalid scope types", function()
		expect(function()
			store:get(123, key)
		end).toThrow("string expected, got number")

		expect(function()
			store:set({}, key, "value")
		end).toThrow("string expected, got table")
	end)

	it("throws an error for invalid key types", function()
		expect(function()
			store:get(scope, {})
		end).toThrow("string expected, got table")

		expect(function()
			store:set(scope, false, "value")
		end).toThrow("string expected, got boolean")
	end)

	it("ensures userIds are an array of numbers", function()
		expect(function()
			store:set(scope, key, "value", { "invalidId" })
		end).toThrow("number expected, got string")

		expect(function()
			store:set(scope, key, "value", "notAnArray")
		end).toThrow("table expected, got string")
	end)

	it("ensures metadata is an optional table", function()
		expect(function()
			store:set(scope, key, "value", nil, "notATable")
		end).toThrow("table expected, got string")
	end)

	it("throws an error for invalid transform function in update", function()
		expect(function()
			store:update(scope, key, "notAFunction")
		end).toThrow("expected a mock object, got string")

		expect(function()
			store:update(scope, key, function()
				error("error in transform function")
			end)
		end).toThrow("error in transform function")
	end)
end)
