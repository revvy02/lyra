local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local JsonPatch = require(ReplicatedStorage.Packages.Lyra.JsonPatch)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

-- Helper function to check roundtrip operations
local function checkRoundtrip(input: any, output: any, expectedPatch: { any })
	local actualPatch = JsonPatch.createPatch(input, output)

	expect(actualPatch).toEqual(expectedPatch)

	local actualOutput = table.clone(input)
	local result = JsonPatch.applyPatch(actualOutput, actualPatch)
	expect(result).toEqual(output)
end

--[[
    Utilities to generate random JSON-like data:
    - Booleans, numbers, strings, arrays, objects
    - No nil (can't store nil in a Lua table, doesn't map well to JSON null)
    - Up to a certain depth to prevent runaway recursion
--]]

-- Characters to choose from for random string generation
local ALPHANUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

local function randomString(r: Random, length: number): string
	local buf = {}
	for _ = 1, length do
		local index = r:NextInteger(1, #ALPHANUM)
		table.insert(buf, string.sub(ALPHANUM, index, index))
	end
	return table.concat(buf)
end

local function randomPrimitive(r: Random)
	local choices = { "boolean", "number", "string" }
	local choice = choices[r:NextInteger(1, #choices)]

	if choice == "boolean" then
		return r:NextNumber() < 0.5
	elseif choice == "number" then
		-- Typical integer range
		return r:NextInteger(-1000, 1000)
	elseif choice == "string" then
		return randomString(r, r:NextInteger(1, 12)) -- 1-12 char strings
	end
end

-- Recursively build a random array
local function randomArray(r: Random, depth: number, maxDepth: number): { any }
	local arr = {}
	local length = r:NextInteger(0, 5) -- Smallish arrays
	for _ = 1, length do
		table.insert(arr, randomValue(r, depth + 1, maxDepth))
	end
	return arr
end

-- Recursively build a random object
local function randomObject(r: Random, depth: number, maxDepth: number): { [string]: any }
	local obj = {}
	local numKeys = r:NextInteger(0, 5) -- up to 5 keys
	for _ = 1, numKeys do
		local key = randomString(r, r:NextInteger(1, 5))
		obj[key] = randomValue(r, depth + 1, maxDepth)
	end
	return obj
end

function randomValue(r: Random, depth: number, maxDepth: number): any
	-- If we reached max depth, return a primitive
	if depth >= maxDepth then
		return randomPrimitive(r)
	end

	-- Decide if we make a primitive, array, or object
	local choices = { "primitive", "array", "object" }
	local choice = choices[r:NextInteger(1, #choices)]
	if choice == "primitive" then
		return randomPrimitive(r)
	elseif choice == "array" then
		return randomArray(r, depth, maxDepth)
	elseif choice == "object" then
		return randomObject(r, depth, maxDepth)
	end
end

-- Helper to clone a table deeply
local function deepClone(value)
	-- If not a table, return directly
	if type(value) ~= "table" then
		return value
	end

	local copy
	if #value > 0 then
		-- Probably an array
		copy = {}
		for i, v in ipairs(value) do
			copy[i] = deepClone(v)
		end
	else
		-- Probably a map/dict
		copy = {}
		for k, v in pairs(value) do
			copy[k] = deepClone(v)
		end
	end
	return copy
end

describe("JsonPatch", function()
	describe("Fuzz Tests for JSON Patch", function()
		-- Generate fuzz test cases
		local r = Random.new(12345) -- Seed for reproducibility
		local fuzzTestCount = 200 -- Tweak as desired
		local fuzzTests = {}

		for i = 1, fuzzTestCount do
			-- Randomly generate input & output tables
			local input = randomValue(r, 0, 3) -- up to 3 levels deep
			local output = randomValue(r, 0, 3) -- up to 3 levels deep

			-- if i == 307 then
			table.insert(fuzzTests, {
				idx = i,
				name = string.format("Fuzz test #%d", i),
				input = input,
				output = output,
			})
			-- print(input, output)
			-- end
		end

		it.each(fuzzTests)("$name", function(testCase)
			-- Create the patch
			local patch = JsonPatch.createPatch(testCase.input, testCase.output)
			-- print(patch)

			-- Apply it to a fresh clone of the input
			local result = deepClone(testCase.input)
			result = JsonPatch.applyPatch(result, patch)

			-- Expect result to match output
			expect(result).toEqual(testCase.output)
		end)
	end)

	describe("Regression", function()
		it("Array reordering 1", function()
			local input = {
				[1] = "a",
			}

			local output = {
				[1] = "b",
				[2] = "c",
			}

			local patch = JsonPatch.createPatch(input, output)

			local result = deepClone(input)
			result = JsonPatch.applyPatch(result, patch)

			expect(result).toEqual(output)
		end)

		it("Array reordering 2", function()
			local input = {
				[1] = {
					["foo"] = "a",
				},
			}

			local output = {
				[1] = {
					["bar"] = "b",
				},
			}

			local patch = JsonPatch.createPatch(input, output)
			-- print(patch)

			local result = deepClone(input)
			result = JsonPatch.applyPatch(result, patch)

			expect(result).toEqual(output)
		end)

		it("Array reordering 3", function()
			local input = {
				[1] = {
					["ROQB"] = {
						[1] = "z5GCHio",
						[2] = "4XlAshaOf",
						[3] = "S",
						[4] = "4kWjPxrRT",
					},
				},
			}

			local output = {
				[1] = {
					["2"] = "jJks7tw",
					["D"] = {
						[1] = true,
						[2] = false,
						[3] = true,
						[4] = -922,
					},
				},
			}

			local patch = JsonPatch.createPatch(input, output)

			local result = deepClone(input)
			result = JsonPatch.applyPatch(result, patch)

			expect(result).toEqual(output)
		end)

		it("Array reordering 4", function()
			local input = {
				[1] = 1,
			}
			local output = {
				[1] = 1,
				[2] = 2,
				[3] = 3,
				[4] = 4,
			}

			local patch = JsonPatch.createPatch(input, output)
			-- print(patch)

			local result = deepClone(input)
			result = JsonPatch.applyPatch(result, patch)

			expect(result).toEqual(output)
		end)
	end)

	describe("Basic RFC Examples", function()
		local rfcExamples = {
			{
				name = "A.1. Adding an Object Member",
				input = { foo = "bar" },
				patch = { { op = "add", path = "/baz", value = "qux" } },
				expected = { foo = "bar", baz = "qux" },
			},
			{
				name = "A.2. Adding an Array Element",
				input = { foo = { "bar", "baz" } },
				patch = { { op = "add", path = "/foo/1", value = "qux" } },
				expected = { foo = { "bar", "qux", "baz" } },
			},
			{
				name = "A.3. Removing an Object Member",
				input = { baz = "qux", foo = "bar" },
				patch = { { op = "remove", path = "/baz" } },
				expected = { foo = "bar" },
			},
			{
				name = "A.4. Removing an Array Element",
				input = { foo = { "bar", "qux", "baz" } },
				patch = { { op = "remove", path = "/foo/1" } },
				expected = { foo = { "bar", "baz" } },
			},
			{
				name = "A.5. Replacing a Value",
				input = { baz = "qux", foo = "bar" },
				patch = { { op = "replace", path = "/baz", value = "boo" } },
				expected = { baz = "boo", foo = "bar" },
			},
			{
				name = "A.6. Adding a Nested Member Object",
				input = { foo = "bar" },
				patch = { { op = "add", path = "/child", value = { grandchild = {} } } },
				expected = { foo = "bar", child = { grandchild = {} } },
			},
			{
				name = "A.7. Adding an Array Value",
				input = { foo = { "bar" } },
				patch = { { op = "add", path = "/foo/-", value = { "abc", "def" } } },
				expected = { foo = { "bar", { "abc", "def" } } },
			},
		}

		it.each(rfcExamples)("$name", function(example)
			local result = table.clone(example.input)
			result = JsonPatch.applyPatch(result, example.patch)
			expect(result).toEqual(example.expected)
		end)
	end)

	describe("Operation Requirements", function()
		describe("'add' operation", function()
			local addTestCases = {
				{
					name = "add to root document",
					input = {},
					patch = { { op = "add", path = "", value = { foo = "bar" } } },
					expected = { foo = "bar" },
				},
				{
					name = "add new member to existing object",
					input = { foo = { bar = "baz" } },
					patch = { { op = "add", path = "/foo/qux", value = "quux" } },
					expected = { foo = { bar = "baz", qux = "quux" } },
				},
				{
					name = "replace existing member when adding",
					input = { foo = "bar" },
					patch = { { op = "add", path = "/foo", value = "baz" } },
					expected = { foo = "baz" },
				},
			}

			it.each(addTestCases)("$name", function(testCase)
				local result = table.clone(testCase.input)
				result = JsonPatch.applyPatch(result, testCase.patch)
				expect(result).toEqual(testCase.expected)
			end)

			it("requires value member", function()
				expect(function()
					JsonPatch.applyPatch({}, {
						{ op = "add", path = "/foo" },
					})
				end).toThrow("'add' operation requires 'path' and 'value'")
			end)

			it("errors when parent does not exist", function()
				expect(function()
					JsonPatch.applyPatch({ foo = "bar" }, {
						{ op = "add", path = "/baz/bat", value = "qux" },
					})
				end).toThrow("Parent path segment 'baz' does not exist for 'add'")
			end)
		end)

		describe("'remove' operation", function()
			local removeTestCases = {
				{
					name = "remove from root",
					input = { foo = "bar" },
					patch = { { op = "remove", path = "" } },
					expected = nil,
				},
				{
					name = "remove nested member",
					input = { foo = { bar = { baz = "qux" } } },
					patch = { { op = "remove", path = "/foo/bar/baz" } },
					expected = { foo = { bar = {} } },
				},
			}

			it.each(removeTestCases)("$name", function(testCase)
				local result = table.clone(testCase.input)
				result = JsonPatch.applyPatch(result, testCase.patch)
				expect(result).toEqual(testCase.expected)
			end)

			it("errors when target does not exist", function()
				expect(function()
					JsonPatch.applyPatch({ foo = "bar" }, {
						{ op = "remove", path = "/baz" },
					})
				end).toThrow("Cannot remove non-existent key 'baz'")
			end)
		end)

		describe("'replace' operation", function()
			local replaceTestCases = {
				{
					name = "replace root",
					input = { foo = "bar" },
					patch = { { op = "replace", path = "", value = { baz = "qux" } } },
					expected = { baz = "qux" },
				},
				{
					name = "replace array element",
					input = { foo = { "bar", "baz" } },
					patch = { { op = "replace", path = "/foo/1", value = "qux" } },
					expected = { foo = { "bar", "qux" } },
				},
			}

			it.each(replaceTestCases)("$name", function(testCase)
				local result = table.clone(testCase.input)
				result = JsonPatch.applyPatch(result, testCase.patch)
				expect(result).toEqual(testCase.expected)
			end)

			it("errors when target does not exist", function()
				expect(function()
					JsonPatch.applyPatch({ foo = "bar" }, {
						{ op = "replace", path = "/baz", value = "qux" },
					})
				end).toThrow("Cannot replace non-existent path 'baz'")
			end)
		end)
	end)

	describe("Array Operations", function()
		local arrayTestCases = {
			{
				name = "add to beginning of array",
				input = { foo = { "bar", "baz" } },
				patch = { { op = "add", path = "/foo/0", value = "qux" } },
				expected = { foo = { "qux", "bar", "baz" } },
			},
			{
				name = "add to middle of array",
				input = { foo = { "bar", "baz", "qux" } },
				patch = { { op = "add", path = "/foo/1", value = "xyz" } },
				expected = { foo = { "bar", "xyz", "baz", "qux" } },
			},
			{
				name = "append using -",
				input = { foo = { "bar", "baz" } },
				patch = { { op = "add", path = "/foo/-", value = "qux" } },
				expected = { foo = { "bar", "baz", "qux" } },
			},
		}

		it.each(arrayTestCases)("$name", function(testCase)
			local result = table.clone(testCase.input)
			result = JsonPatch.applyPatch(result, testCase.patch)
			expect(result).toEqual(testCase.expected)
		end)

		describe("error cases", function()
			it("errors on add beyond end", function()
				expect(function()
					JsonPatch.applyPatch({ foo = { "bar" } }, {
						{ op = "add", path = "/foo/3", value = "qux" },
					})
				end).toThrow("Array add index 3 out of bounds for length 1")
			end)

			it("errors on out of bounds removal", function()
				expect(function()
					JsonPatch.applyPatch({ foo = { "bar" } }, {
						{ op = "remove", path = "/foo/1" },
					})
				end).toThrow("Array remove index 1 out of bounds for length 1")
			end)

			it("errors on negative indices", function()
				expect(function()
					JsonPatch.applyPatch({ foo = { "bar" } }, {
						{ op = "add", path = "/foo/-1", value = "qux" },
					})
				end).toThrow()
			end)
		end)

		it("handles sequential operations correctly", function()
			local doc = {
				foo = { "bar", "baz" },
			}
			local patch = {
				{ op = "add", path = "/foo/1", value = "qux" }, -- ["bar", "qux", "baz"]
				{ op = "remove", path = "/foo/2" }, -- ["bar", "qux"]
				{ op = "add", path = "/foo/-", value = "baz" }, -- ["bar", "qux", "baz"]
			}
			JsonPatch.applyPatch(doc, patch)
			expect(doc.foo).toEqual({ "bar", "qux", "baz" })
		end)
	end)

	describe("Error Handling", function()
		it("ignores extra members in operations", function()
			local doc = { foo = "bar" }
			JsonPatch.applyPatch(doc, {
				{ op = "add", path = "/baz", value = "qux", extra = "ignored" },
			})
			expect(doc).toEqual({ foo = "bar", baz = "qux" })
		end)

		describe("required fields", function()
			local errorCases = {
				{
					name = "missing op field",
					patch = { { path = "/foo", value = "bar" } },
					error = "Invalid patch operation: 'op' must be a string",
				},
				{
					name = "missing path field",
					patch = { { op = "add", value = "bar" } },
					error = "Patch operation missing valid 'path' string",
				},
				{
					name = "missing value field in add",
					patch = { { op = "add", path = "/foo" } },
					error = "'add' operation requires 'path' and 'value'",
				},
				{
					name = "missing value field in replace",
					patch = { { op = "replace", path = "/foo" } },
					error = "'replace' operation requires 'value'",
				},
			}

			it.each(errorCases)("$name", function(testCase)
				local doc = { foo = "bar" }
				expect(function()
					JsonPatch.applyPatch(doc, testCase.patch)
				end).toThrow(testCase.error)
			end)
		end)

		describe("operation validation", function()
			it("errors on invalid operation name", function()
				local doc = { foo = "bar" }
				expect(function()
					JsonPatch.applyPatch(doc, {
						{ op = "invalid", path = "/foo" },
					})
				end).toThrow("Unknown or unimplemented operation: invalid")
			end)

			it("errors on non-string operation name", function()
				local doc = { foo = "bar" }
				expect(function()
					JsonPatch.applyPatch(doc, {
						{ op = 123, path = "/foo" },
					})
				end).toThrow("Invalid patch operation: 'op' must be a string")
			end)
		end)
	end)

	describe("createPatch", function()
		local diffTestCases = {
			{
				name = "simple value change",
				input = { foo = "bar" },
				output = { foo = "baz" },
				expected = {
					{ op = "replace", path = "/foo", value = "baz" },
				},
			},
			{
				name = "array reordering",
				input = { foo = { "bar", "baz", "qux" } },
				output = { foo = { "baz", "qux", "bar" } },
				expected = {
					{ op = "remove", path = "/foo/0" },
					{ op = "add", path = "/foo/-", value = "bar" },
				},
			},
			{
				name = "object member removal",
				input = { foo = "bar", baz = "qux" },
				output = { foo = "bar" },
				expected = {
					{ op = "remove", path = "/baz" },
				},
			},
			{
				name = "nested object changes",
				input = { foo = { bar = { baz = "qux" } } },
				output = { foo = { bar = { baz = "changed" } } },
				expected = {
					{ op = "replace", path = "/foo/bar/baz", value = "changed" },
				},
			},
			{
				name = "array element addition",
				input = { foo = { "bar" } },
				output = { foo = { "bar", "baz" } },
				expected = {
					{ op = "add", path = "/foo/-", value = "baz" },
				},
			},
		}

		it.each(diffTestCases)("$name", function(testCase)
			checkRoundtrip(testCase.input, testCase.output, testCase.expected)
		end)

		describe("array diff optimization", function()
			it("generates minimal array operations", function()
				local input = { arr = { 1, 2, 3, 4, 5 } }
				local output = { arr = { 1, 3, 4, 2, 5 } }

				local patch = JsonPatch.createPatch(input, output)

				-- Apply the patch and verify
				local result = table.clone(input)
				result = JsonPatch.applyPatch(result, patch)
				expect(result).toEqual(output)

				-- Verify patch is reasonably sized (not one operation per element)
				expect(#patch).toBeLessThan(#input.arr)
			end)
		end)
	end)
end)
