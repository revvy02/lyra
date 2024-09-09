local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local PromiseQueue = require(ReplicatedStorage.Packages.Lyra.PromiseQueue)
local Promise = require(ReplicatedStorage.Packages.Promise)

local jest = JestGlobals.jest
local it = JestGlobals.it
local expect = JestGlobals.expect
local describe = JestGlobals.describe

describe("PromiseQueue", function()
	describe("new", function()
		it("correctly initializes an empty queue", function()
			local queue = PromiseQueue.new()
			expect(queue._queue).toEqual({})
		end)
	end)

	describe("add", function()
		it("correctly adds a new callback to the queue", function()
			local queue = PromiseQueue.new()
			local callback = jest.fn()
			return queue:add(callback):andThen(function()
				expect(queue._queue).toEqual({})
				expect(callback).toHaveBeenCalled()
			end)
		end)

		it("executes the callback when the queue is processed", function()
			local queue = PromiseQueue.new()
			local callback = jest.fn()
			return queue:add(callback):andThen(function()
				expect(callback).toHaveBeenCalled()
			end)
		end)

		it("returns a promise that resolves when the callback completes successfully", function()
			local queue = PromiseQueue.new()
			local callback = jest.fn(function()
				return "Success"
			end)
			return queue:add(callback):andThen(function(result)
				expect(result).toBe("Success")
				expect(queue._queue).toEqual({})
			end)
		end)

		it("returns a promise that rejects if the callback throws an error", function()
			local queue = PromiseQueue.new()
			local callback = function()
				error("error inside callback")
			end
			return expect(queue:add(callback)).rejects.toMatch("error inside callback")
		end)

		it("ensures callbacks are executed in the order they are added", function()
			local queue = PromiseQueue.new()
			local callOrder = {}
			local callback1 = jest.fn(function()
				table.insert(callOrder, 1)
			end)
			local callback2 = jest.fn(function()
				table.insert(callOrder, 2)
			end)
			local p1 = queue:add(callback1)
			local p2 = queue:add(callback2)
			return Promise.all({ p1, p2 }):andThen(function()
				expect(callOrder).toEqual({ 1, 2 })
			end)
		end)

		it("ensures callbacks are executed in the order they are added even if they yield", function()
			local queue = PromiseQueue.new()
			local callOrder = {}
			local callback1 = jest.fn(function()
				table.insert(callOrder, 1)
				Promise.delay(0.1):await()
			end)
			local callback2 = jest.fn(function()
				table.insert(callOrder, 2)
			end)
			local p1 = queue:add(callback1)
			local p2 = queue:add(callback2)
			return Promise.all({ p1, p2 }):andThen(function()
				expect(callOrder).toEqual({ 1, 2 })
			end)
		end)

		it("handles concurrent adds correctly", function()
			local queue = PromiseQueue.new()
			local callOrder = {}
			local callback1 = jest.fn(function()
				Promise.delay(0.1):await()
				table.insert(callOrder, 1)
			end)
			local callback2 = jest.fn(function()
				table.insert(callOrder, 2)
			end)
			local p1 = queue:add(callback1)
			local p2 = queue:add(callback2)
			return Promise.all({ p1, p2 }):andThen(function()
				expect(callOrder).toEqual({ 1, 2 })
			end)
		end)

		it("ensures proper error handling and propagation within the queue", function()
			local queue = PromiseQueue.new()
			local callback1 = jest.fn(function()
				task.wait(0.1)
				error("propagated error")
			end)
			local callback2 = jest.fn()
			local p1 = queue:add(callback1)
			local p2 = queue:add(callback2)

			return expect(p2:andThen(function()
				return expect(p1).rejects.toMatch("propagated error")
			end)).resolves.never.toBeDefined()
		end)
	end)

	describe("_addResumableBlock", function()
		it("adds a resumable block to the queue", function()
			local queue = PromiseQueue.new()
			local blockPromise = PromiseQueue._addResumableBlock(queue)
			expect(#queue._queue).toBe(1)
			return blockPromise
		end)

		it("returns a promise that resolves with a function to unblock the queue", function()
			local queue = PromiseQueue.new()
			return PromiseQueue._addResumableBlock(queue):andThen(function(resume)
				expect(typeof(resume)).toBe("function")
			end)
		end)

		it("correctly blocks the queue until the unblock function is called", function()
			local queue = PromiseQueue.new()
			local blocked = false
			local callback = jest.fn(function()
				expect(blocked).toBe(true)
			end)

			PromiseQueue._addResumableBlock(queue):andThen(function(resume)
				blocked = true
				resume()
			end)

			return queue:add(callback):andThen(function()
				expect(callback).toHaveBeenCalled()
			end)
		end)

		it("ensures the unblock function resumes the queue processing", function()
			local queue = PromiseQueue.new()
			local callback = jest.fn()
			return PromiseQueue._addResumableBlock(queue)
				:andThen(function(resume)
					local p = queue:add(callback)
					resume()
					return p
				end)
				:andThen(function()
					expect(callback).toHaveBeenCalled()
				end)
		end)
	end)

	describe("multiQueueAdd", function()
		it("correctly adds a callback to multiple queues", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local callback = jest.fn()

			PromiseQueue.multiQueueAdd({ queue1, queue2 }, callback)

			expect(callback).toHaveBeenCalled()
		end)

		it("returns a promise that resolves when the callback completes successfully", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local callback = jest.fn(function()
				return "Success"
			end)

			return PromiseQueue.multiQueueAdd({ queue1, queue2 }, callback):andThen(function(result)
				expect(result).toBe("Success")
			end)
		end)

		it("returns a promise that rejects if the callback throws an error", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local callback = jest.fn(function()
				error("propagated error")
			end)

			return expect(PromiseQueue.multiQueueAdd({ queue1, queue2 }, callback)).rejects.toMatch("propagated error")
		end)

		it("ensures all queues are blocked before the callback is executed", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local blocked = false
			local callback = jest.fn(function()
				expect(blocked).toBe(true)
			end)

			queue1:add(function()
				Promise.delay(0.1):await()
				blocked = true
			end)
			PromiseQueue.multiQueueAdd({ queue1, queue2 }, callback)
			return Promise.delay(0.2):andThen(function()
				expect(callback).toHaveBeenCalled()
			end)
		end)

		it("unblocks all queues after the callback completes", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local callback1 = jest.fn()
			local callback2 = jest.fn()

			PromiseQueue.multiQueueAdd({ queue1, queue2 }, function() end)
			local p1 = queue1:add(callback1)
			local p2 = queue2:add(callback2)

			return Promise.all({ p1, p2 }):andThen(function()
				expect(callback1).toHaveBeenCalled()
				expect(callback2).toHaveBeenCalled()
			end)
		end)

		it("handles edge cases where some queues are empty and others are not", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local callback1 = jest.fn()
			local callback2 = jest.fn()

			queue1:add(function()
				Promise.delay(0.1):await()
			end)

			local p1 = PromiseQueue.multiQueueAdd({ queue1, queue2 }, callback1)
			local p2 = queue2:add(callback2)

			return Promise.all({ p1, p2 }):andThen(function()
				expect(callback1).toHaveBeenCalled()
				expect(callback2).toHaveBeenCalled()
			end)
		end)

		it("verifies that the callback is executed only once all queues are blocked", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local blocked1 = false
			local blocked2 = false
			local callback = jest.fn(function()
				expect(blocked1).toBe(true)
				expect(blocked2).toBe(true)
			end)

			queue1:add(function()
				Promise.delay(0.1):await()
				blocked1 = true
			end)
			queue2:add(function()
				Promise.delay(0.2):await()
				blocked2 = true
			end)
			return PromiseQueue.multiQueueAdd({ queue1, queue2 }, callback):andThen(function()
				expect(callback).toHaveBeenCalled()
			end)
		end)

		it("ensures proper cleanup and resume of all queues even if the callback fails", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local callback1 = jest.fn()
			local callback2 = jest.fn()

			PromiseQueue.multiQueueAdd({ queue1, queue2 }, function()
				error("propagated error")
			end):catch(function() end)
			local p2 = queue1:add(callback1)
			local p3 = queue2:add(callback2)

			return Promise.allSettled({ p2, p3 }):andThen(function()
				expect(callback1).toHaveBeenCalled()
				expect(callback2).toHaveBeenCalled()
				expect(queue1._queue).toEqual({})
				expect(queue2._queue).toEqual({})
			end)
		end)

		it("tests with varying numbers of queues and callbacks for robustness", function()
			local queues = {}
			local callbacks = {}
			local promises = {}

			for _ = 1, 5 do
				local queue = PromiseQueue.new()
				table.insert(queues, queue)

				local callback = jest.fn()
				table.insert(callbacks, callback)
				table.insert(promises, queue:add(callback))
			end

			table.insert(promises, PromiseQueue.multiQueueAdd(queues, function() end))

			return Promise.all(promises):andThen(function()
				for _, callback in callbacks do
					expect(callback).toHaveBeenCalled()
				end
			end)
		end)
	end)

	describe("Additional Redundancy Tests", function()
		it("simulate large-scale usage with heavy queue operations", function()
			local queue = PromiseQueue.new()
			local numCallbacks = 1000
			local promises = {}

			for _ = 1, numCallbacks do
				table.insert(promises, queue:add(function() end))
			end

			return Promise.all(promises)
		end)

		it("verify consistency and order of execution across multiple queues", function()
			local queue1 = PromiseQueue.new()
			local queue2 = PromiseQueue.new()
			local callOrder = {}
			local callback1 = jest.fn(function()
				table.insert(callOrder, 1)
			end)
			local callback2 = jest.fn(function()
				table.insert(callOrder, 2)
			end)

			local p1 = queue1:add(callback1)
			local p2 = queue2:add(callback2)

			return Promise.all({
				queue1:add(function() end),
				queue2:add(function() end),
				p1,
				p2,
			}):andThen(function()
				expect(callOrder).toEqual({ 1, 2 })
			end)
		end)

		it("ensure data integrity and proper error handling during intensive queue processing", function()
			local queue = PromiseQueue.new()
			local numCallbacks = 1000
			local successCount = 0
			local errorCount = 0
			local promises = {}

			for i = 1, numCallbacks do
				local shouldError = i % 2 == 0
				table.insert(
					promises,
					queue
						:add(function()
							if shouldError then
								error("Error")
							else
								successCount += 1
							end
						end)
						:catch(function()
							errorCount += 1
						end)
				)
			end

			return Promise.all(promises):andThen(function()
				expect(successCount).toBe(numCallbacks / 2)
				expect(errorCount).toBe(numCallbacks / 2)
			end)
		end)
	end)
end)
