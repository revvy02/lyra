--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local HashMapInterface = require(ReplicatedStorage.Packages.Lyra.HashMapInterface)
local Locks = require(ReplicatedStorage.Packages.Lyra.Locks)
local Promise = require(ReplicatedStorage.Packages.Lyra.Promise)
local Log = require(ReplicatedStorage.Packages.Lyra.Log)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Types = require(ReplicatedStorage.Packages.Lyra.Types)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("Locks", function()
	local hashMapInterface
	local mockMemoryStoreService
	local storeContext: Types.StoreContext<any>
	local logger

	beforeEach(function()
		mockMemoryStoreService = MockMemoryStoreService.createMockService()
		hashMapInterface = HashMapInterface.new(mockMemoryStoreService)
		Log.level = "info"
		logger = Log.createLogger(function() end)
		storeContext = {
			hashMapInterface = hashMapInterface,
			lockScope = "test-locks",
			logger = logger,
		} :: Types.StoreContext<any>
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	local function acquireLock(key: string?, config: { [string]: any }?)
		local params = {
			storeContext = storeContext,
			key = key or "testKey",
			acquireAttempts = 3,
			duration = 30,
			refreshInterval = 5,
		}
		if config then
			for k, v in config do
				params[k] = v
			end
		end
		return Locks.acquireLock(params)
	end

	describe("acquireLock", function()
		describe("basic locking behavior", function()
			it("should successfully acquire a lock when none exists", function()
				local promise = acquireLock():andThen(function(lock)
					expect(lock.isLocked()).toBe(true)
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should prevent other processes from acquiring the same lock", function()
				local promise = acquireLock():andThen(function(lock1)
					expect(lock1.isLocked()).toBe(true)
					local lock2Promise = acquireLock()
					for _ = 1, 35 do
						jest.advanceTimersByTime(1000)
					end
					return expect(lock2Promise).rejects.toMatch("lock remained")
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should allow acquiring the lock after it expires", function()
				local promise = acquireLock("testKey", { duration = 1 }):andThen(function(lock1)
					expect(lock1.isLocked()).toBe(true)

					for _ = 1, 2 do
						jest.advanceTimersByTime(1000)
					end
					expect(lock1.isLocked()).toBe(false)

					local acquire2 = acquireLock("testKey"):andThen(function(lock2)
						expect(lock2.isLocked()).toBe(true)
					end)
					jest.advanceTimersByTime(1000)

					return acquire2
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should generate unique lock IDs for each acquisition", function()
				local promise = acquireLock():andThen(function(lock1)
					local id1Handle = hashMapInterface:get(storeContext.lockScope, "testKey")
					jest.advanceTimersByTime(500)
					local id1 = id1Handle.promise:expect()

					lock1.release()
					jest.advanceTimersByTime(1000)

					acquireLock()
					jest.advanceTimersByTime(1000)

					local id2Handle = hashMapInterface:get(storeContext.lockScope, "testKey")
					jest.advanceTimersByTime(500)
					local id2 = id2Handle.promise:expect()

					expect(id1).never.toBe(id2)
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)
		end)

		describe("lock refresh behavior", function()
			it("should maintain lock", function()
				local promise = acquireLock("testKey", { duration = 10, refreshInterval = 2 }):andThen(function(lock)
					expect(lock.isLocked()).toBe(true)

					for _ = 1, 40 do
						jest.advanceTimersByTime(100)
						expect(lock.isLocked()).toBe(true)
					end
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should extend lock duration after successful refresh", function()
				local promise = acquireLock("testKey", { duration = 5, refreshInterval = 2 }):andThen(function(lock)
					for _ = 1, 4 do
						jest.advanceTimersByTime(1000)
						expect(lock.isLocked()).toBe(true)
					end

					for _ = 1, 20 do
						jest.advanceTimersByTime(100)
						expect(lock.isLocked()).toBe(true)
					end
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should stop refreshing after lock is released", function()
				local refreshCount = 0

				local hashMap = mockMemoryStoreService:GetHashMap(storeContext.lockScope)
				local ogUpdate = hashMap.UpdateAsync
				hashMap.UpdateAsync = function(self, ...)
					refreshCount += 1
					return ogUpdate(self, ...)
				end

				local promise = acquireLock("testKey", { duration = 10, refreshInterval = 2 }):andThen(function(lock)
					for _ = 1, 3 do
						jest.advanceTimersByTime(1000)
					end
					local initialCount = refreshCount
					lock.release()
					initialCount += 1 -- lock.release adds 1 update call
					jest.advanceTimersByTime(500)
					expect(refreshCount).toBe(initialCount)

					for _ = 1, 3 do
						jest.advanceTimersByTime(1000)
					end
					expect(refreshCount).toBe(initialCount)
				end)

				jest.advanceTimersByTime(1000)
				return promise
			end)
		end)

		describe("lock release behavior", function()
			it("should successfully release an acquired lock", function()
				local promise = acquireLock():andThen(function(lock)
					expect(lock.isLocked()).toBe(true)
					lock.release()
					jest.advanceTimersByTime(500)
					expect(lock.isLocked()).toBe(false)
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should allow immediate reacquisition after release", function()
				local promise = acquireLock():andThen(function(lock1)
					lock1.release()

					jest.advanceTimersByTime(500)

					expect(lock1.isLocked()).toBe(false)

					local p2 = acquireLock():andThen(function(lock2)
						expect(lock2.isLocked()).toBe(true)
					end)

					jest.advanceTimersByTime(5000)

					return p2
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should handle multiple release calls gracefully", function()
				local promise = acquireLock():andThen(function(lock)
					lock.release()
					jest.advanceTimersByTime(500)

					expect(lock.isLocked()).toBe(false)

					lock.release()
					jest.advanceTimersByTime(500)

					expect(lock.isLocked()).toBe(false)
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should execute onLockLost callbacks when lock expires", function()
				local promise = acquireLock("testKey", { duration = 5 }):andThen(function(lock)
					local mock, fn = jest.fn()
					lock.onLockLost(fn)

					jest.advanceTimersByTime(6000)
					expect(mock).toBeCalledTimes(1)
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)
		end)

		describe("error handling", function()
			it("should reject if lock cannot be acquired within duration", function()
				local promise = acquireLock():andThen(function()
					local lock2Promise = acquireLock("testKey", { duration = 2 })

					for _ = 1, 3 do
						jest.advanceTimersByTime(90000)
					end
					return expect(lock2Promise).rejects.toMatch("lock remained")
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should clean up resources if cancelled during acquisition", function()
				local acquirePromise = acquireLock()
				acquirePromise:cancel()
				jest.advanceTimersByTime(1000)

				local promise = acquireLock():andThen(function(lock)
					expect(lock.isLocked()).toBe(true)
				end)
				jest.advanceTimersByTime(90000)
				return promise
			end)
		end)

		describe("callback management", function()
			it("should properly register and unregister onLockLost callbacks", function()
				local callback1, fn1 = jest.fn()
				local callback2, fn2 = jest.fn()

				local promise = acquireLock("testKey", { duration = 5 }):andThen(function(lock)
					local unregister1 = lock.onLockLost(fn1)
					lock.onLockLost(fn2)

					unregister1()

					for _ = 1, 6 do
						jest.advanceTimersByTime(1000)
					end
					expect(callback1).never.toBeCalled()
					expect(callback2).toBeCalledTimes(1)
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should execute all registered callbacks on expiry", function()
				local callback1, fn1 = jest.fn()
				local callback2, fn2 = jest.fn()
				local callback3, fn3 = jest.fn()

				local promise = acquireLock("testKey", { duration = 5 }):andThen(function(lock)
					lock.onLockLost(fn1)
					lock.onLockLost(fn2)
					lock.onLockLost(fn3)

					for _ = 1, 6 do
						jest.advanceTimersByTime(1000)
					end
					expect(callback1).toBeCalledTimes(1)
					expect(callback2).toBeCalledTimes(1)
					expect(callback3).toBeCalledTimes(1)
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)
		end)
	end)

	describe("probeLockActive", function()
		describe("basic probing behavior", function()
			it("should return true for active locks", function()
				local promise = acquireLock():andThen(function()
					local p = Locks.probeLockActive({
						storeContext = storeContext,
						key = "testKey",
					}):andThen(function(isActive)
						expect(isActive).toBe(true)
					end)
					jest.advanceTimersByTime(500)
					return p
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should return false for expired locks", function()
				local promise = acquireLock("testKey", { duration = 2 }):andThen(function()
					jest.advanceTimersByTime(3000)
					local p = Locks.probeLockActive({
						storeContext = storeContext,
						key = "testKey",
					}):andThen(function(isActive)
						expect(isActive).toBe(false)
					end)
					jest.advanceTimersByTime(500)
					return p
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)

			it("should return false for non-existent locks", function()
				local promise = Locks.probeLockActive({
					storeContext = storeContext,
					key = "nonExistentKey",
				}):andThen(function(isActive)
					expect(isActive).toBe(false)
				end)
				jest.advanceTimersByTime(1000)
				return promise
			end)
		end)

		describe("error handling", function()
			it("should handle hashmap errors gracefully", function()
				local hashMap = mockMemoryStoreService:GetHashMap(storeContext.lockScope)
				hashMap.GetAsync = function()
					error("Simulated error")
				end

				local promise = Locks.probeLockActive({
					storeContext = storeContext,
					key = "testKey",
				})
				jest.advanceTimersByTime(1000)
				return expect(promise).rejects.toBeDefined()
			end)
		end)
	end)

	describe("integration scenarios", function()
		it("should handle multiple concurrent lock attempts", function()
			local successfulLocks = 0
			local failedLocks = 0

			local promises = {}
			for _ = 1, 5 do
				table.insert(
					promises,
					acquireLock("sharedKey")
						:andThen(function()
							successfulLocks += 1
						end)
						:catch(function()
							failedLocks += 1
						end)
				)
				jest.advanceTimersByTime(100)
			end

			for _ = 1, 35 do
				jest.advanceTimersByTime(1000)
			end

			local promise = Promise.all(promises):andThen(function()
				expect(successfulLocks).toBe(1)
				expect(failedLocks).toBe(4)
			end)
			jest.advanceTimersByTime(1000)
			return promise
		end)
	end)
end)
