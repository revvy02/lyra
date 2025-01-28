local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local PromiseQueue = require(ReplicatedStorage.Packages.Lyra.PromiseQueue)
local Promise = require(ReplicatedStorage.Packages.Promise)

local jest = JestGlobals.jest
local it = JestGlobals.it
local expect = JestGlobals.expect
local describe = JestGlobals.describe
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local function makePromiseQueue()
	return PromiseQueue.new({ logger = { log = function() end } :: any })
end

describe("PromiseQueue", function()
	local queue

	beforeEach(function()
		jest.useFakeTimers()
		queue = makePromiseQueue()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	describe("new", function()
		it("correctly initializes an empty queue", function()
			expect(queue._queue).toEqual({})
		end)
	end)

	describe("add", function()
		it("executes callbacks in order", function()
			local callOrder = {}
			local callback1 = jest.fn(function()
				task.wait(1)
				table.insert(callOrder, 1)
			end)
			local callback2 = jest.fn(function()
				table.insert(callOrder, 2)
			end)
			local p1 = queue:add(callback1)
			local p2 = queue:add(callback2)

			jest.runAllTimers()

			return Promise.all({ p1, p2 }):andThen(function()
				expect(callOrder).toEqual({ 1, 2 })
			end)
		end)

		it("handles errors and continues processing", function()
			local callback1 = jest.fn(function()
				error("test error")
			end)
			local callback2 = jest.fn()
			local p1 = queue:add(callback1)
			local p2 = queue:add(callback2)

			jest.runAllTimers()

			return Promise.all({
				p1:catch(function() end),
				p2,
			}):andThen(function()
				expect(callback1).toHaveBeenCalled()
				expect(callback2).toHaveBeenCalled()
			end)
		end)

		it("supports cancellation to remove unprocessed item", function()
			local callback = jest.fn()
			queue:add(function()
				task.wait(1)
			end)
			local promise = queue:add(callback)

			promise:cancel()

			jest.runAllTimers()

			expect(#queue._queue).toBe(0)
			expect(callback).never.toHaveBeenCalled()
		end)

		it("times out long-running operations", function()
			local promise = queue:add(function()
				task.wait(5 * 60)
			end)

			jest.advanceTimersByTime(100_000)
			return expect(promise).rejects.toMatch("Timed out")
		end)
	end)

	describe("multiQueueAdd", function()
		it("coordinates execution across multiple queues", function()
			local queue2 = makePromiseQueue()
			local blocked1 = false
			local blocked2 = false
			local callback = jest.fn(function()
				expect(blocked1).toBe(true)
				expect(blocked2).toBe(true)
			end)

			queue:add(function()
				task.wait(1)
				blocked1 = true
			end)
			queue2:add(function()
				task.wait(2)
				blocked2 = true
			end)

			jest.runAllTimers()

			return PromiseQueue.multiQueueAdd({ queue, queue2 }, callback):andThen(function()
				expect(callback).toHaveBeenCalled()
			end)
		end)

		it("handles errors in coordinated operations", function()
			local queue2 = makePromiseQueue()
			local callback1 = jest.fn()
			local callback2 = jest.fn()

			PromiseQueue.multiQueueAdd({ queue, queue2 }, function()
				error("test error")
			end):catch(function() end)
			local p1 = queue:add(callback1)
			local p2 = queue2:add(callback2)

			jest.runAllTimers()

			return Promise.allSettled({ p1, p2 }):andThen(function()
				expect(callback1).toHaveBeenCalled()
				expect(callback2).toHaveBeenCalled()
				expect(queue._queue).toEqual({})
				expect(queue2._queue).toEqual({})
			end)
		end)
	end)

	describe("_addResumableBlock", function()
		it("blocks and resumes queue processing", function()
			local blocked = false
			local callback = jest.fn(function()
				expect(blocked).toBe(true)
			end)

			PromiseQueue._addResumableBlock(queue):andThen(function(resume)
				blocked = true
				resume()
			end)

			jest.runAllTimers()

			return queue:add(callback):andThen(function()
				expect(callback).toHaveBeenCalled()
			end)
		end)
	end)
end)
