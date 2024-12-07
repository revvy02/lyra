local ReplicatedStorage = game:GetService("ReplicatedStorage")

local splitUtf8String = require(script.Parent.Parent.splitUtf8String)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

describe("splitUtf8String", function()
	it("correctly splits a non-empty string within the maxSizeBytes limit", function()
		local result = splitUtf8String("Hello, world!", 5)
		expect(result).toEqual({ "Hello", ", wor", "ld!" })
	end)

	it("correctly handles empty string input", function()
		local result = splitUtf8String("", 5)
		expect(result).toEqual({})
	end)

	it("throws an error when maxSizeBytes is less than or equal to 0", function()
		expect(function()
			splitUtf8String("Hello, world!", 0)
		end).toThrow("splitUtf8String: expected maxSizeBytes to be greater than 0, got 0")
	end)

	it("correctly splits a string with multibyte UTF-8 characters", function()
		local result = splitUtf8String("こんにちは世界", 9)
		expect(result).toEqual({ "こんに", "ちは世", "界" })
	end)

	it("correctly handles string where a character's byte size exceeds maxSizeBytes", function()
		local result = splitUtf8String("こんにちは世界", 3)
		expect(result).toEqual({ "こ", "ん", "に", "ち", "は", "世", "界" })
	end)

	it("correctly handles edge cases where maxSizeBytes is exactly the size of a character", function()
		local result = splitUtf8String("Hello", 1)
		expect(result).toEqual({ "H", "e", "l", "l", "o" })
	end)

	it("ensures no loss of data during splitting", function()
		local result = splitUtf8String("Hello, world!", 5)
		expect(table.concat(result)).toBe("Hello, world!")
	end)

	it("maintains correct order of sections", function()
		local result = splitUtf8String("Hello, world!", 5)
		expect(result).toEqual({ "Hello", ", wor", "ld!" })
	end)

	it("correctly splits very large strings", function()
		local largeString = string.rep("a", 1000)
		local result = splitUtf8String(largeString, 100)
		expect(#result).toBe(10)
		expect(table.concat(result)).toBe(largeString)
	end)

	it("handles invalid UTF-8 strings gracefully", function()
		expect(function()
			splitUtf8String("Hello\xC0\xAFworld", 5)
		end).toThrow("splitUtf8String: invalid UTF-8 sequence detected at offset 1")
	end)

	it("ensures that each section is a valid UTF-8 string", function()
		local result = splitUtf8String("こんにちは世界", 9)
		for _, section in result do
			expect(utf8.len(section)).never.toBe(nil)
		end
	end)

	it("boundary test for strings with characters at the maxSizeBytes limit", function()
		local result = splitUtf8String("こんにちは", 3)
		expect(result).toEqual({ "こ", "ん", "に", "ち", "は" })
	end)

	it("boundary test for single character strings", function()
		local result = splitUtf8String("a", 1)
		expect(result).toEqual({ "a" })
	end)

	it("validates type of returned sections", function()
		local result = splitUtf8String("Hello, world!", 5)
		for _, section in result do
			expect(typeof(section)).toBe("string")
		end
	end)
end)
