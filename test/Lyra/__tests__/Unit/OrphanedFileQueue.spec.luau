local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local OrphanedFileQueue = require(ReplicatedStorage.Packages.Lyra.OrphanedFileQueue)

local jest = JestGlobals.jest
local it = JestGlobals.it
local expect = JestGlobals.expect
local describe = JestGlobals.describe
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

describe("OrphanedFileQueue", function()
	local queue
	local mockProcessQueueItem

	beforeEach(function()
		jest.useFakeTimers()
		queue = OrphanedFileQueue.new()
		mockProcessQueueItem = jest.fn(function()
			task.wait(0.1)
			return true
		end)
		queue.processQueueItem = mockProcessQueueItem
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	describe("new", function()
		it("correctly initializes an empty queue", function()
			expect(queue.queue).toEqual({})
		end)
	end)

	describe("markFile", function()
		it("adds a file to the queue", function()
			local file = { id = "test" }
			queue:markFile("key1", file)
			expect(#queue.queue).toBe(1)
			expect(queue.queue[1].key).toBe("key1")
			expect(queue.queue[1].file).toBe(file)
			expect(queue.queue[1].beingProcessed).toBe(false)
		end)

		it("does not add duplicate files", function()
			local file = { id = "test" }
			queue:markFile("key1", file)
			queue:markFile("key2", file)
			expect(#queue.queue).toBe(1)
		end)

		it("starts processing when first item is added", function()
			local file = { id = "test" }
			queue:markFile("key1", file)
			jest.runAllTimers()
			expect(mockProcessQueueItem).toHaveBeenCalled()
		end)
	end)

	describe("markFiles", function()
		it("adds multiple files to the queue", function()
			local files = {
				{ id = "test1" },
				{ id = "test2" },
			}
			queue:markFiles("key1", files)
			expect(#queue.queue).toBe(2)
		end)

		it("does not add duplicate files across multiple calls", function()
			local file1 = { id = "test1" }
			local file2 = { id = "test2" }
			queue:markFiles("key1", { file1, file2 })
			queue:markFiles("key2", { file1 })
			expect(#queue.queue).toBe(2)
		end)
	end)

	describe("_processQueueItems", function()
		it("processes items in the queue", function()
			local file1 = { id = "test1" }
			local file2 = { id = "test2" }
			queue:markFiles("key1", { file1, file2 })

			jest.advanceTimersByTime(1000)

			expect(mockProcessQueueItem).toHaveBeenCalledTimes(2)
			expect(#queue.queue).toBe(0)
		end)

		it("removes items from queue when processed", function()
			local file1 = { id = "test1" }
			local file2 = { id = "test2" }
			queue:markFiles("key1", { file1, file2 })

			mockProcessQueueItem.mockImplementation(function(entry)
				return entry.file.id == "test1"
			end)

			jest.advanceTimersByTime(1000)

			expect(#queue.queue).toBe(1)
			expect(queue.queue[1].file.id).toBe("test2")
		end)

		it("waits between processing items", function()
			local file1 = { id = "test1" }
			local file2 = { id = "test2" }
			queue:markFiles("key1", { file1, file2 })

			jest.advanceTimersByTime(50)
			expect(mockProcessQueueItem).toHaveBeenCalledTimes(1)

			jest.advanceTimersByTime(200)
			expect(mockProcessQueueItem).toHaveBeenCalledTimes(2)
		end)
	end)
end)
