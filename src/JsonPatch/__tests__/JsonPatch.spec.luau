--[[
	Based on https://github.com/Starcounter-Jack/JSON-Patch

	(The MIT License)

	Copyright (c) 2013, 2014, 2020 Joachim Wester

	Permission is hereby granted, free of charge, to any person obtaining
	a copy of this software and associated documentation files (the
	'Software'), to deal in the Software without restriction, including
	without limitation the rights to use, copy, modify, merge, publish,
	distribute, sublicense, and/or sell copies of the Software, and to
	permit persons to whom the Software is furnished to do so, subject to
	the following conditions:

	The above copyright notice and this permission notice shall be
	included in all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
	EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
	MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
	IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
	CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
	TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
	SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local JsonPatch = require(ReplicatedStorage.Packages.Lyra.JsonPatch)
local Tables = require(ReplicatedStorage.Packages.Lyra.Tables)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local SPEC_TESTS = {
	{
		comment = "A.1.  Adding an Object Member",
		doc = { foo = "bar" },
		patch = { { op = "add", path = "/baz", value = "qux" } },
		expected = {
			baz = "qux",
			foo = "bar",
		},
	},
	{
		comment = "A.2.  Adding an Array Element",
		doc = {
			foo = { "bar", "baz" },
		},
		patch = { { op = "add", path = "/foo/1", value = "qux" } },
		expected = {
			foo = { "bar", "qux", "baz" },
		},
	},
	{
		comment = "A.3.  Removing an Object Member",
		doc = {
			baz = "qux",
			foo = "bar",
		},
		patch = { { op = "remove", path = "/baz" } },
		expected = {
			foo = "bar",
		},
	},
	{
		comment = "A.4.  Removing an Array Element",
		doc = {
			foo = { "bar", "qux", "baz" },
		},
		patch = { { op = "remove", path = "/foo/1" } },
		expected = {
			foo = { "bar", "baz" },
		},
	},
	{
		comment = "A.5.  Replacing a Value",
		doc = {
			baz = "qux",
			foo = "bar",
		},
		patch = { { op = "replace", path = "/baz", value = "boo" } },
		expected = {
			baz = "boo",
			foo = "bar",
		},
	},
	-- A.6 omitted - move not implemented
	-- A.7 omitted - move not implemented
	-- A.8 omitted - test not implemented
	-- A.9 omitted - test not implemented
	{
		comment = "A.10. Adding a nested Member Object",
		doc = {
			foo = "bar",
		},
		patch = { { op = "add", path = "/child", value = { grandchild = {} } } },
		expected = {
			foo = "bar",
			child = {
				grandchild = {},
			},
		},
	},
	{
		comment = "A.11. Ignoring Unrecognized Elements",
		doc = {
			foo = "bar",
		},
		patch = { { op = "add", path = "/baz", value = "qux", xyz = 123 } },
		expected = {
			foo = "bar",
			baz = "qux",
		},
	},
	{
		comment = "A.12. Adding to a Non-existent Target",
		doc = {
			foo = "bar",
		},
		patch = { { op = "add", path = "/baz/bat", value = "qux" } },
		error = "add to a non-existent target",
	},
	-- A.13 omitted - duplicate keys not possible in Luau
	{
		comment = "A.14. ~ Escape Ordering",
		doc = {
			["/"] = 9,
			["~1"] = 10,
		},
		patch = { { op = "add", path = "/~001", value = 11 } },
		expected = {
			["/"] = 9,
			["~1"] = 10,
			["~01"] = 11,
		},
	},
	-- A.15 omitted - duplicate keys not possible in Luau
	{
		comment = "A.16. Adding an Array Value",
		doc = {
			foo = { "bar" },
		},
		patch = { { op = "add", path = "/foo/-", value = { "abc", "def" } } },
		expected = {
			foo = { "bar", { "abc", "def" } },
		},
	},
}

local APPLY_TESTS = {
	{ comment = "empty list, empty docs", doc = {}, patch = {}, expected = {} },
	{ comment = "empty patch list", doc = { foo = 1 }, patch = {}, expected = { foo = 1 } },
	{
		comment = "toplevel array",
		doc = {},
		patch = { { op = "add", path = "/-", value = "foo" } },
		expected = { "foo" },
	},
	{ comment = "toplevel array, no change", doc = { "foo" }, patch = {}, expected = { "foo" } },
	{
		comment = "toplevel object, numeric string",
		doc = {},
		patch = { { op = "add", path = "/foo", value = "1" } },
		expected = { foo = "1" },
	},
	{
		comment = "toplevel object, integer",
		doc = {},
		patch = { { op = "add", path = "/foo", value = 1 } },
		expected = { foo = 1 },
	},
	{
		comment = "Add, / target",
		doc = {},
		patch = { { op = "add", path = "/", value = 1 } },
		expected = { [""] = 1 },
	},
	{
		comment = "Add composite value at top level",
		doc = { foo = 1 },
		patch = { { op = "add", path = "/bar", value = { 1, 2 } } },
		expected = { foo = 1, bar = { 1, 2 } },
	},
	{
		comment = "Add into composite value",
		doc = { foo = 1, baz = { { qux = "hello" } } },
		patch = { { op = "add", path = "/baz/0/foo", value = "world" } },
		expected = { foo = 1, baz = { { qux = "hello", foo = "world" } } },
	},
	{
		comment = "Add out of upper bounds throws",
		doc = { bar = { 1, 2 } },
		patch = { { op = "add", path = "/bar/8", value = "5" } },
		error = "Array add index 8 out of bounds for length 2",
	},
	{
		comment = "Add out of lower bounds throws",
		doc = { bar = { 1, 2 } },
		patch = { { op = "add", path = "/bar/-1", value = "5" } },
		error = "Array add index -1 out of bounds for length 2",
	},
	{
		comment = "Add to object",
		doc = { foo = 1 },
		patch = { { op = "add", path = "/bar", value = true } },
		expected = { foo = 1, bar = true },
	},
	{
		comment = "Add to object",
		doc = { foo = 1 },
		patch = { { op = "add", path = "/bar", value = false } },
		expected = { foo = 1, bar = false },
	},
	{
		comment = "0 can be an array index or object element name",
		doc = { foo = 1 },
		patch = { { op = "add", path = "/0", value = "bar" } },
		expected = { foo = 1, ["0"] = "bar" },
	},
	{
		comment = "Add to middle of array",
		doc = { "foo", "sil" },
		patch = { { op = "add", path = "/1", value = "bar" } },
		expected = { "foo", "bar", "sil" },
	},
	{
		comment = "Add to beginning of array",
		doc = { "foo", "sil" },
		patch = { { op = "add", path = "/0", value = "bar" } },
		expected = { "bar", "foo", "sil" },
	},
	{
		comment = "Add to end of array",
		doc = { "foo", "sil" },
		patch = { { op = "add", path = "/-", value = "bar" } },
		expected = { "foo", "sil", "bar" },
	},
	{
		comment = "Object operation on array throws",
		doc = { "foo", "sil" },
		patch = { { op = "add", path = "/bar", value = 42 } },
		error = "Object operation on array target",
	},
	{
		comment = "value in array add not flattened",
		doc = { "foo", "sil" },
		patch = { { op = "add", path = "/1", value = { "bar", "baz" } } },
		expected = { "foo", { "bar", "baz" }, "sil" },
	},
	{
		comment = "remove member from object",
		doc = { foo = 1, bar = { 1, 2, 3, 4 } },
		patch = { { op = "remove", path = "/bar" } },
		expected = { foo = 1 },
	},
	{
		comment = "remove deeply nested item",
		doc = { foo = 1, baz = { { qux = "hello" } } },
		patch = { { op = "remove", path = "/baz/0/qux" } },
		expected = { foo = 1, baz = { {} } },
	},
	{
		comment = "replace member in object",
		doc = { foo = 1, baz = { { qux = "hello" } } },
		patch = { { op = "replace", path = "/foo", value = { 1, 2, 3, 4 } } },
		expected = { foo = { 1, 2, 3, 4 }, baz = { { qux = "hello" } } },
	},
	{
		comment = "replace deeply nested item",
		doc = { foo = { 1, 2, 3, 4 }, baz = { { qux = "hello" } } },
		patch = { { op = "replace", path = "/baz/0/qux", value = "world" } },
		expected = { foo = { 1, 2, 3, 4 }, baz = { { qux = "world" } } },
	},
	{
		comment = "replace in array",
		doc = { "foo" },
		patch = { { op = "replace", path = "/0", value = "bar" } },
		expected = { "bar" },
	},
	{
		comment = "replace in array with number",
		doc = { "" },
		patch = { { op = "replace", path = "/0", value = 0 } },
		expected = { 0 },
	},
	{
		comment = "replace with true",
		doc = { "" },
		patch = { { op = "replace", path = "/0", value = true } },
		expected = { true },
	},
	{
		comment = "replace with false",
		doc = { "" },
		patch = { { op = "replace", path = "/0", value = false } },
		expected = { false },
	},
	{
		doc = { "foo", "sil" },
		patch = { { op = "replace", path = "/1", value = { "bar", "baz" } } },
		expected = { "foo", { "bar", "baz" } },
		comment = "value in array replace not flattened",
	},
	{
		comment = "replace whole document",
		doc = { foo = "bar" },
		patch = { { op = "replace", path = "", value = { baz = "qux" } } },
		expected = { baz = "qux" },
	},
	{
		comment = "replacing the root of the document is possible with add",
		doc = { foo = "bar" },
		patch = { { op = "add", path = "", value = { baz = "qux" } } },
		expected = { baz = "qux" },
	},
	{
		comment = 'Adding to "/-" adds to the end of the array',
		doc = { 1, 2 },
		patch = { { op = "add", path = "/-", value = { foo = { "bar", "baz" } } } },
		expected = { 1, 2, { foo = { "bar", "baz" } } },
	},
	{
		comment = 'Adding to "/-" adds to the end of the array, even n levels down',
		doc = { 1, 2, { 3, { 4, 5 } } },
		patch = { { op = "add", path = "/2/1/-", value = { foo = { "bar", "baz" } } } },
		expected = { 1, 2, { 3, { 4, 5, { foo = { "bar", "baz" } } } } },
	},
	{
		comment = "test remove with bad number should fail",
		doc = { foo = 1, baz = { { qux = "hello" } } },
		patch = { { op = "remove", path = "/baz/1e0/qux" } },
		error = "Path segment '1e0' is not a valid array index",
	},
	{
		comment = "test remove on array",
		doc = { 1, 2, 3, 4 },
		patch = { { op = "remove", path = "/0" } },
		expected = { 2, 3, 4 },
	},
	{
		comment = "test repeated removes",
		doc = { 1, 2, 3, 4 },
		patch = { { op = "remove", path = "/1" }, { op = "remove", path = "/2" } },
		expected = { 1, 3 },
	},
	{
		comment = "test remove with bad index should fail",
		doc = { 1, 2, 3, 4 },
		patch = { { op = "remove", path = "/1e0" } },
		error = "remove op shouldn't remove from array with bad number",
	},
	{
		comment = "test replace with bad number should fail",
		doc = { "" },
		patch = { { op = "replace", path = "/1e0", value = false } },
		error = "replace op shouldn't replace in array with bad number",
	},
	{
		comment = "test add with bad number should fail",
		doc = { "foo", "sil" },
		patch = { { op = "add", path = "/1e0", value = "bar" } },
		error = "add op shouldn't add to array with bad number",
	},
	{
		comment = "missing 'value' parameter to add",
		doc = { 1 },
		patch = { { op = "add", path = "/-" } },
		error = "missing 'value' parameter",
	},
	{
		comment = "missing 'value' parameter to replace",
		doc = { 1 },
		patch = { { op = "replace", path = "/0" } },
		error = "missing 'value' parameter",
	},
	{
		comment = "unrecognized op should fail",
		doc = { foo = 1 },
		patch = { { op = "spam", path = "/foo", value = 1 } },
		error = "Unrecognized op 'spam'",
	},
	{
		comment = "add to ambiguous object",
		doc = { ["1"] = "foo", ["01"] = "bar" },
		patch = { { op = "add", path = "/1", value = "baz" } },
		expected = { ["1"] = "baz", ["01"] = "bar" },
	},
	{
		comment = "append to ambiguous object",
		doc = { ["1"] = "foo", ["01"] = "bar" },
		patch = { { op = "add", path = "/-", value = "baz" } },
		expected = { ["1"] = "foo", ["01"] = "bar", ["-"] = "baz" },
	},
	{
		comment = "add to ambiguous deep object",
		doc = { ["1"] = { ["2"] = "foo" }, ["01"] = "bar" },
		patch = { { op = "add", path = "/1/2", value = "baz" } },
		expected = { ["1"] = { ["2"] = "baz" }, ["01"] = "bar" },
	},
	{
		comment = "append to ambiguous deep object",
		doc = { ["1"] = { ["2"] = "foo" }, ["01"] = "bar" },
		patch = { { op = "add", path = "/1/-", value = "baz" } },
		expected = { ["1"] = { ["2"] = "foo", ["-"] = "baz" }, ["01"] = "bar" },
	},
	{
		comment = "add to ambiguous deep array",
		doc = { ["-"] = { "foo" }, ["01"] = "bar" },
		patch = { { op = "add", path = "/-/-", value = "baz" } },
		expected = { ["-"] = { "foo", "baz" }, ["01"] = "bar" },
	},
}

describe("JsonPatch", function()
	describe("Spec tests", function()
		it.each(SPEC_TESTS)("$comment", function(testCase)
			if testCase.disabled then
				return
			end

			if testCase.error then
				expect(function()
					JsonPatch.applyPatch(testCase.doc, testCase.patch)
				end).toThrow(testCase.error)
			else
				local input = Tables.copyDeep(testCase.doc)
				local result = JsonPatch.applyPatch(input, testCase.patch)
				expect(result).toEqual(testCase.expected)

				input = Tables.copyDeep(testCase.doc)
				local generatedPatch = JsonPatch.createPatch(input, testCase.expected)
				result = JsonPatch.applyPatch(input, generatedPatch)
				expect(result).toEqual(testCase.expected)
			end
		end)
	end)

	describe("Test cases", function()
		it.each(APPLY_TESTS)("$comment", function(testCase)
			if testCase.disabled then
				return
			end

			if testCase.error then
				expect(function()
					JsonPatch.applyPatch(testCase.doc, testCase.patch)
				end).toThrow(testCase.error)
			else
				local input = Tables.copyDeep(testCase.doc)
				local result = JsonPatch.applyPatch(input, testCase.patch)
				expect(result).toEqual(testCase.expected)

				input = Tables.copyDeep(testCase.doc)
				local generatedPatch = JsonPatch.createPatch(input, testCase.expected)
				result = JsonPatch.applyPatch(input, generatedPatch)
				expect(result).toEqual(testCase.expected)
			end
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
			local result = JsonPatch.applyPatch(input, patch)

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
			local result = JsonPatch.applyPatch(input, patch)

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
			local result = JsonPatch.applyPatch(input, patch)

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
			local result = JsonPatch.applyPatch(input, patch)

			expect(result).toEqual(output)
		end)
	end)
end)
