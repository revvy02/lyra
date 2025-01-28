--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Tables = require(ReplicatedStorage.Packages.Lyra.Tables)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("Store", function()
	local Store

	local mockData
	local mockMemory
	local store

	local function makeStore(config)
		config = Tables.mergeShallow({
			name = "session test",
			template = { coins = 0, inventory = {} },
			schema = function(data)
				return typeof(data) == "table" and typeof(data.coins) == "number" and typeof(data.inventory) == "table",
					"schema validation failed"
			end,

			migrationSteps = {},

			dataStoreService = mockData,
			memoryStoreService = mockMemory,
		}, config)

		return Store.createStore(config)
	end

	local function crash()
		local snap = MockDataStoreService.snapshot(mockData)
		for _ = 1, 5 do
			jest.advanceTimersByTime(1000)
		end
		mockData = MockDataStoreService.new()
		mockMemory = MockMemoryStoreService.new()
		store = makeStore()
		MockDataStoreService.restore(mockData, snap)
	end

	beforeEach(function()
		local realConstants = jest.requireActual(ReplicatedStorage.Packages.Lyra.Constants)
		jest.mock(ReplicatedStorage.Packages.Lyra.Constants, function()
			return Tables.mergeShallow(realConstants, {
				MAX_CHUNK_SIZE = 50,
			})
		end)

		Store = require(ReplicatedStorage.Packages.Lyra.Store)

		mockData = MockDataStoreService.new()
		mockMemory = MockMemoryStoreService.new()

		store = makeStore()

		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	describe("Partial Write / Orphaned File Creation", function()
		it.skip("clean up file partial write failure", function()
			-- 1) Trigger a large file write so multiple shards are created
			-- 2) Simulate a partial or failed write that leaves behind shards
			--    (some logic that triggers a mid-write crash or error)
			-- 3) Confirm store now has an orphaned file in its session or gets queued
			--    for cleanup behind the scenes
			-- 4) Advance timers in increments to simulate time passing
			-- 5) Expect that the orphaned shards eventually disappear from mockData
			--    (the queue cleans them up)
			-- 6) Validate no error is thrown, and store no longer sees the orphaned file
			store:load("player1")
			jest.advanceTimersByTime(1000)

			store:update("player1", function(data)
				data.coins = 100
				return true
			end)

			local setMock, realSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
			setMock
				.mockImplementation(function()
					print("aaaa")
					error("fake error", 0)
				end)
				.mockImplementationOnce(realSet)

			local save1 = store:save("player1")
			jest.advanceTimersByTime(1000)

			setMock.mockImplementation(realSet)
			store:unload("player1")
			jest.advanceTimersByTime(1000)

			local removeMock = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)
			jest.advanceTimersByTime(100000)

			expect(removeMock).toBeCalledTimes(1)
		end)

		it.todo("verify partial shards exist before cleanup")
		it.todo("verify shards are removed from DataStore after processing")

		it("should handle concurrent writes leaving multiple orphaned files", function()
			-- 1) Kick off multiple large writes in parallel on different keys
			-- 2) Force partial completion on some
			-- 3) Wait for the queue to process
			-- 4) Ensure all orphaned shards are eventually removed
		end)
		it.todo("check queue is processing each file eventually")
		it.todo("verify store can still load/unload or do normal operations while cleanup runs")
	end)

	describe("Budget Issues During Cleanup", function()
		it("should retry orphan file cleanup if the request budget is insufficient at first", function()
			-- 1) Force the budget to be artificially low (in your MockDataStore, perhaps set the
			--    getRequestBudgetForRequestType(...) to return a small or zero value)
			-- 2) Mark an orphaned file so OrphanedFileQueue tries to remove shards
			-- 3) Confirm that the removal fails initially (the queue logs debug, or you can detect it from store logs)
			-- 4) Then "restore" the budget and advance timers so the queue tries again
			-- 5) Confirm that the shards are successfully cleaned up on retry
		end)
		it.todo("simulate multiple attempts until budget is sufficient")
	end)

	describe("Store Closure and Orphaned Files", function()
		it("should complete orphaned-file cleanup before store:close() resolves if cleanup is in progress", function()
			-- 1) Start a partial write that orphans some files
			-- 2) Immediately call store:close()
			-- 3) Advance timers
			-- 4) The store:close() promise should not resolve until cleanup finishes,
			--    or it might reject with errors if something goes wrong
		end)
		it.todo("ensure store:close waits for queue processing to finish or is robust to errors")

		it("should not process new orphaned files after store is closed", function()
			-- 1) Orphan some files
			-- 2) Wait for partial cleanup
			-- 3) Close the store
			-- 4) Attempt to orphan more files (somehow, though the store is closed—maybe it's a no-op)
			-- 5) Confirm new orphaned files do NOT get processed
		end)
		it.todo("check that any queue attempt after closure is a no-op or logs a warning")
	end)

	describe("Crash & Recovery Scenarios", function()
		it("should resume cleanup after a crash+restore when partially through removing shards", function()
			-- 1) Orphan multiple large-file shards
			-- 2) Wait so that the queue is mid-processing (some shards removed, some not)
			-- 3) Simulate a 'crash' by snapshot/restore the mockData
			-- 4) Recreate the store, advance timers
			-- 5) Confirm eventually all shards from the old orphan are removed
		end)
		it.todo("ensure partial progress doesn't break the next store instance's queue logic")
	end)

	describe("Transactions with Large Files", function()
		it("should handle orphaned files from a multi-key transaction that partially commits some shards", function()
			-- 1) Load multiple keys, each with large data
			-- 2) Perform a 'tx' that tries to update them (maybe we set a big new field on each key)
			-- 3) Force an error halfway, leaving some shards orphaned
			-- 4) Confirm the queue eventually cleans up leftover shards
			-- 5) Confirm final data is correct for each key
		end)
		it.todo("check that store data is consistent even if a partial transaction left shards orphaned")
	end)

	describe("Edge-Case Validations", function()
		it("should ignore already-removed shards and proceed without error", function()
			-- If a shard gets removed externally or is missing for some reason,
			-- the queue should skip or log but not crash.
		end)
		it.todo("verify no error if a shard is missing mid-cleanup")

		it("should not mistakenly remove shards from a newly-written file with the same shardId", function()
			-- Possibly test the scenario if a new write reuses the same shardId
			-- before cleanup finishes. Or you can confirm it doesn't happen with
			-- some store-level ID logic. If it's a known edge case, test that we
			-- don't remove the 'new' file's shards incorrectly.
		end)
		it.todo("verify store doesn't re-use shard IDs or incorrectly remove fresh shards")

		it("should properly handle cleaning up extremely large files (e.g., hundreds of shards)", function()
			-- Stress test scenario with a high shard count
			-- Ensure that repeated DataStore calls eventually remove all shards
			-- We'll use `jest.advanceTimersByTime(...)` in a loop to confirm it eventually finishes
		end)
		it.todo("long-term stress test for high volume of shards in a single orphaned file")
	end)
end)
