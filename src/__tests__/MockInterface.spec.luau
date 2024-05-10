local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockInterface = require(ReplicatedStorage.Packages.Mix.DataStoreInterface.MockInterface)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

local jest = JestGlobals.jest
local it = JestGlobals.it
local expect = JestGlobals.expect
local mock = jest.fn

it("sets and gets a value correctly", function()
	local key = "testKey"
	local scope = "testScope"
	local store = MockInterface.new()
	local value = { data = "testData" }
	return store
		:set(scope, key, value)
		:andThen(function()
			return store:get(scope, key)
		end)
		:andThen(function(result)
			expect(result).toEqual(value)
		end)
end)

it("updates a value correctly", function()
	local key = "testKey"
	local scope = "testScope"
	local store = MockInterface.new()
	local value, updatedValue = { data = "testData" }, { data = "updatedData" }
	return store
		:set(scope, key, value)
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
end)

it("removes a value correctly", function()
	local key = "testKey"
	local scope = "testScope"
	local store = MockInterface.new()
	local value = { data = "testData" }
	return store
		:set(scope, key, value)
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

it("returns nil for a value that has not been set", function()
	local key = "nonExistentKey"
	local scope = "nonExistentScope"
	local store = MockInterface.new()
	return store:get(scope, key):andThen(function(result)
		expect(result).toBeNil()
	end)
end)

it("correctly handles different data types", function()
	local key = "testKey"
	local scope = "testScope"
	local store = MockInterface.new()
	local values = {
		["string"] = "a string",
		["number"] = 42,
		["table"] = { data = "tableData" },
		["boolean"] = true,
		["nil"] = nil,
	}

	return Promise.all(Sift.Dictionary.map(values, function(value, dataType)
		return store
			:set(scope, key .. dataType, value)
			:andThen(function()
				return store:get(scope, key .. dataType)
			end)
			:andThen(function(result)
				expect(result).toEqual(value)
			end)
	end))
end)

it("ensures unique values per scope and key", function()
	local store = MockInterface.new()
	local scopes = { "scope1", "scope2" }
	local keys = { "key1", "key2" }
	local value1, value2 = { data = "data1" }, { data = "data2" }

	-- Set value1 in scope1/key1 and value2 in scope2/key2
	return Promise.new(function(resolve)
		store:set(scopes[1], keys[1], value1):expect()
		store:set(scopes[2], keys[2], value2):expect()

		-- Verify that the values are unique and correctly assigned
		store
			:get(scopes[1], keys[1])
			:andThen(function(result)
				expect(result).toEqual(value1)
			end)
			:expect()

		store
			:get(scopes[2], keys[2])
			:andThen(function(result)
				expect(result).toEqual(value2)
			end)
			:expect()

		-- Verify that changing a value in one scope/key does not affect the other
		local updatedValue = { data = "updatedData" }
		store:set(scopes[1], keys[1], updatedValue):expect()
		store
			:get(scopes[1], keys[1])
			:andThen(function(result)
				expect(result).toEqual(updatedValue)
			end)
			:expect()
		store
			:get(scopes[2], keys[2])
			:andThen(function(result)
				expect(result).toEqual(value2)
			end)
			:expect()

		resolve()
	end)
end)

it("handles setting and getting complex nested tables", function()
	local key = "complexKey"
	local scope = "complexScope"
	local store = MockInterface.new()
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

it("verifies that updates do not mutate the original value", function()
	local key = "mutationKey"
	local scope = "mutationScope"
	local store = MockInterface.new()
	local originalValue = { data = "originalData" }

	return store
		:set(scope, key, originalValue)
		:andThen(function()
			return store:update(scope, key, function(oldValue)
				local newValue = { data = oldValue.data .. "Updated" }
				return newValue
			end)
		end)
		:andThen(function()
			return store:get(scope, key)
		end)
		:andThen(function(updatedValue)
			expect(updatedValue.data).never.toEqual(originalValue.data)
			expect(updatedValue.data).toEqual("originalDataUpdated")
		end)
end)

it("correctly handles multiple updates to the same key", function()
	local key = "multiUpdateKey"
	local scope = "multiUpdateScope"
	local store = MockInterface.new()
	local initialValue = { count = 1 }

	local updateFunction = function(oldValue)
		return { count = oldValue.count + 1 }
	end

	store
		:set(scope, key, initialValue)
		:andThen(function()
			store:update(scope, key, updateFunction):await()
			return store:update(scope, key, updateFunction)
		end)
		:andThen(function()
			return store:get(scope, key)
		end)
		:andThen(function(result)
			expect(result.count).toEqual(3) -- Initial value of 1, plus two updates
		end)
end)

it("handles concurrent updates correctly", function()
	local key = "concurrentKey"
	local scope = "concurrentScope"
	local store = MockInterface.new()
	local initialValue = { count = 0 }

	-- Create a mock update function
	local updateFunction = mock().mockImplementation(function(oldValue)
		return { count = oldValue.count + 1 }
	end)

	local setPromise = store:set(scope, key, initialValue)

	local updatesCount = 10
	local updates = {}
	for _ = 1, updatesCount do
		table.insert(
			updates,
			setPromise:andThen(function()
				return store:update(scope, key, updateFunction)
			end)
		)
	end

	-- Verify the final value
	Promise.all(updates)
		:andThen(function()
			return store:get(scope, key)
		end)
		:andThen(function(result)
			expect(result.count).toEqual(updatesCount)
			-- Verify the mock update function was called the correct number of times
			expect(#updateFunction.mock.calls).toBe(updatesCount)
			-- Verify the first call was with the initial value
			expect(updateFunction.mock.calls[1][1].count).toBe(0)
		end)
end)

it("sets and gets userIds correctly", function()
	local key = "userIdKey"
	local scope = "userIdScope"
	local store = MockInterface.new()
	local value = { data = "userData" }
	local userIds = { 12345, 67890 }
	return store
		:set(scope, key, value, userIds)
		:andThen(function()
			return store:get(scope, key)
		end)
		:andThen(function(_, keyInfo)
			expect(keyInfo.GetUserIds()).toEqual(userIds)
		end)
end)

it("updates metadata correctly", function()
	local key = "metadataKey"
	local scope = "metadataScope"
	local store = MockInterface.new()
	local value = { data = "metadataValue" }
	local metadata = { important = "yes" }
	return store
		:set(scope, key, value, nil, metadata)
		:andThen(function()
			return store:get(scope, key)
		end)
		:andThen(function(_, keyInfo)
			expect(keyInfo.GetMetadata()).toEqual(metadata)
		end)
end)

it("increments version on update", function()
	local key = "versionKey"
	local scope = "versionScope"
	local store = MockInterface.new()
	local initialValue = { data = "initialData" }
	local previousVersionPromise = store
		:set(scope, key, initialValue)
		:andThen(function()
			return store:get(scope, key)
		end)
		:andThen(function(_, keyInfo)
			return keyInfo.Version
		end)

	return previousVersionPromise:andThen(function(previousVersion)
		return store
			:update(scope, key, function(oldValue)
				return { data = oldValue.data .. "Updated" }
			end)
			:andThen(function()
				return store:get(scope, key)
			end)
			:andThen(function(_, keyInfo)
				expect(keyInfo.Version).never.toBe(previousVersion)
			end)
	end)
end)

it("preserves metadata and userIds on remove", function()
	local key = "removeKey"
	local scope = "removeScope"
	local store = MockInterface.new()
	local value = { data = "removeData" }
	local userIds = { 12345 }
	local metadata = { deleted = "true" }
	return store
		:set(scope, key, value, userIds, metadata)
		:andThen(function()
			return store:remove(scope, key)
		end)
		:andThen(function(_, keyInfo)
			expect(keyInfo.GetUserIds()).toEqual(userIds)
			expect(keyInfo.GetMetadata()).toEqual(metadata)
		end)
end)

it("should throw an error for invalid scope types", function()
	local store = MockInterface.new()
	expect(function()
		store:get(123, "key")
	end).toThrow("string expected, got number")
	expect(function()
		store:set({}, "key", "value")
	end).toThrow("string expected, got table")
end)

it("should throw an error for invalid key types", function()
	local store = MockInterface.new()
	expect(function()
		store:get("scope", {})
	end).toThrow("string expected, got table")
	expect(function()
		store:set("scope", false, "value")
	end).toThrow("string expected, got boolean")
end)

it("should handle non-existent keys gracefully", function()
	local store = MockInterface.new()
	return store:get("nonExistentScope", "nonExistentKey"):andThen(function(result, keyInfo)
		expect(result).toBeNil()
		expect(keyInfo).toBeNil()
	end)
end)

it("should throw an error when userIds are not a table", function()
	local store = MockInterface.new()
	expect(function()
		store:set("scope", "key", "value", "notATable")
	end).toThrow("table expected, got string")
end)

it("should throw an error when metadata is not a table", function()
	local store = MockInterface.new()
	expect(function()
		store:set("scope", "key", "value", nil, "notATable")
	end).toThrow("table expected, got string")
end)

it("should throw an error for invalid transform function in update", function()
	local store = MockInterface.new()
	expect(function()
		store:update("scope", "key", "notAFunction")
	end).toThrow("expected a mock object, got string")
end)
