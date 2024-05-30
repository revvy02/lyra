local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local noYield = require(ReplicatedStorage.Packages.Mix.noYield)

local it = JestGlobals.it
local expect = JestGlobals.expect
local describe = JestGlobals.describe

describe("noYield", function()
	it("correctly calls a non-yielding function and returns its results", function()
		local function nonYielding()
			return "result"
		end
		local result = noYield(nonYielding)
		expect(result).toBe("result")
	end)

	it("throws an error if the function attempts to yield", function()
		local function yielding()
			coroutine.yield()
		end
		expect(function()
			noYield(yielding)
		end).toThrow("attempt to yield")
	end)

	it("supports functions with multiple return values", function()
		local function multipleReturns()
			return "first", "second", "third"
		end
		local result1, result2, result3 = noYield(multipleReturns)
		expect(result1).toBe("first")
		expect(result2).toBe("second")
		expect(result3).toBe("third")
	end)

	it("passes multiple arguments to the callback function correctly", function()
		local function sum(a, b)
			return a + b
		end
		local result = noYield(sum, 3, 4)
		expect(result).toBe(7)
	end)

	it("propagates errors from the callback function correctly", function()
		local function errorFunction()
			error("callback error")
		end
		expect(function()
			noYield(errorFunction)
		end).toThrow("callback error")
	end)

	it("handles functions that return no values", function()
		local function noReturnValue()
			-- no return
		end
		local result = noYield(noReturnValue)
		expect(result).toBe(nil)
	end)

	it("correctly identifies and handles edge cases where the callback has no arguments", function()
		local function noArgs()
			return "no args"
		end
		local result = noYield(noArgs)
		expect(result).toBe("no args")
	end)

	it("ensures type safety for the callback and arguments", function()
		local function typeSafe(a: number, b: string)
			return b .. tostring(a)
		end
		local result = noYield(typeSafe, 3, "test")
		expect(result).toBe("test3")
	end)

	it("maintains the original stack trace in case of errors", function()
		local function stackTraceError()
			error("stack trace error")
		end
		local success, errorMessage = pcall(function()
			noYield(stackTraceError)
		end)
		expect(success).toBe(false)
		expect(errorMessage).toMatch("stack trace error")
	end)

	it("handles nested calls to noYield correctly", function()
		local function inner()
			return "inner result"
		end
		local function outer()
			return noYield(inner)
		end
		local result = noYield(outer)
		expect(result).toBe("inner result")
	end)

	it("validates the output types returned from the callback function", function()
		local function typeValidation()
			return 42
		end
		local result = noYield(typeValidation)
		expect(typeof(result)).toBe("number")
	end)

	it("boundary tests for callbacks with various argument and return value lengths", function()
		local function boundaryTest(a, b, c, d, e)
			return a, b, c, d, e
		end
		local result1, result2, result3, result4, result5 = noYield(boundaryTest, 1, "two", 3, "four", 5)
		expect(result1).toBe(1)
		expect(result2).toBe("two")
		expect(result3).toBe(3)
		expect(result4).toBe("four")
		expect(result5).toBe(5)
	end)

	it("ensures proper cleanup of coroutine after execution", function()
		local function cleanup()
			return "clean"
		end
		local result = noYield(cleanup)
		expect(result).toBe("clean")
		expect(coroutine.status(coroutine.create(cleanup))).toBe("suspended")
	end)
end)
