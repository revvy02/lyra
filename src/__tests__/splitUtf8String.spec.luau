local ReplicatedStorage = game:GetService("ReplicatedStorage")

local splitUtf8String = require(script.Parent.Parent.splitUtf8String)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

describe("splitUtf8String", function()
	it("splits basic ASCII strings correctly when the string length is within maxSizeBytes", function()
		local result = splitUtf8String("Hello, World!", 100)
		expect(result).toEqual({ "Hello, World!" })
	end)

	it("splits basic ASCII strings correctly when the string length exceeds maxSizeBytes", function()
		local result = splitUtf8String("Hello, World!", 5)
		expect(result).toEqual({ "Hello", ", Wor", "ld!" })
	end)

	it("splits at exact maxSizeBytes boundary", function()
		local result = splitUtf8String("Hello", 2)
		expect(result).toEqual({ "He", "ll", "o" })
	end)

	it("handles multi-byte UTF-8 characters correctly", function()
		local result = splitUtf8String("こんにちは", 6) -- Each Japanese character is 3 bytes
		expect(result).toEqual({ "こん", "にち", "は" })
	end)

	it("handles single-character string", function()
		local result = splitUtf8String("A", 1)
		expect(result).toEqual({ "A" })
	end)

	it("handles empty string", function()
		local result = splitUtf8String("", 5)
		expect(result).toEqual({})
	end)

	it("throws error for invalid UTF-8 string", function()
		local invalidUTF8String = "\xff"
		expect(function()
			splitUtf8String(invalidUTF8String, 5)
		end).toThrow("invalid utf8 string")
	end)

	it("throws error for negative maxSizeBytes", function()
		expect(function()
			splitUtf8String("Hello", -5)
		end).toThrow()
	end)

	it("handles zero maxSizeBytes by throwing an error", function()
		expect(function()
			splitUtf8String("Hello", 0)
		end).toThrow()
	end)
end)
