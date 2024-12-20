local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Log = require(ReplicatedStorage.Packages.Lyra.Log)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local OrphanedFileQueue = require(ReplicatedStorage.Packages.Lyra.OrphanedFileQueue)
local Session = require(ReplicatedStorage.Packages.Lyra.Session)
local Types = require(ReplicatedStorage.Packages.Lyra.Types)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("Session", function()
	local mockData
	local mockMemory
	local ctx: Types.StoreContext<any>

	local function loadSession(key: string?, userIds: { number }?)
		local _key = key or "player1"
		return Session.load({
			key = _key,
			storeContext = ctx,
			userIds = userIds,
		})
	end

	beforeEach(function()
		mockData = MockDataStoreService.new()
		mockMemory = MockMemoryStoreService.new()
		ctx = {
			name = "session test",
			template = { coins = 0, inventory = {} },
			schema = function(data)
				return typeof(data) == "table" and typeof(data.coins) == "number" and typeof(data.inventory) == "table"
			end,

			migrationSteps = {},

			dataStoreService = mockData,
			memoryStoreService = mockMemory,

			orphanedFileQueue = OrphanedFileQueue.new(),
			logger = Log.createLogger(function() end),
			changedCallbacks = {},

			recordStore = mockData:GetDataStore("session"),
			shardStore = mockData:GetDataStore("shards"),
			txStore = mockData:GetDataStore("tx"),
			lockHashMap = mockMemory:GetHashMap("locks"),
		}
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	describe("basic session behavior", function()
		it("should load a session with template data", function()
			local promise = loadSession():andThen(function(session)
				return session:get()
			end)
			jest.advanceTimersByTime(1000)
			return expect(promise).resolves.toEqual(ctx.template)
		end)

		it("should track changes correctly", function()
			local promise = loadSession():andThen(function(session)
				-- TODO: sessions are broadly considered unsaved on load
				expect(session:isSaved()).toBe(false)

				session:setData({ coins = 10, inventory = {} })
				expect(session:isSaved()).toBe(false)

				return session:save():andThen(function()
					expect(session:isSaved()).toBe(true)
				end)
			end)
			jest.advanceTimersByTime(1000)
			return promise
		end)

		it("should prevent modifications after session is closed", function()
			local promise = loadSession():andThen(function(session)
				return session:unload():andThen(function()
					return session:update(function(data)
						data.coins += 10
						return true
					end)
				end)
			end)
			jest.advanceTimersByTime(1000)
			return expect(promise).rejects.toEqual("Session is closed")
		end)
	end)

	describe("data validation", function()
		it("should reject invalid data in update", function()
			local promise = loadSession():andThen(function(session)
				return session:update(function(data: any)
					data.coins = "invalid"
					return true
				end)
			end)
			jest.advanceTimersByTime(1000)
			return expect(promise).rejects.toMatch("schema validation failed")
		end)

		it("should maintain data immutability", function()
			local promise = loadSession():andThen(function(session)
				return session:get():andThen(function(data)
					expect(function()
						data.coins = 100
					end).toThrow()
				end)
			end)
			jest.advanceTimersByTime(1000)
			return promise
		end)
	end)

	describe("autosave behavior", function()
		it("should automatically save changes", function()
			local promise = loadSession():andThen(function(session)
				session:startAutosaving()
				session:setData({ coins = 10, inventory = {} })

				jest.advanceTimersByTime(6 * 60 * 1000) -- Autosave interval + buffer

				expect(session:isSaved()).toBe(true)
			end)
			jest.advanceTimersByTime(1000)
			return promise
		end)

		it("should stop autosaving when requested", function()
			local promise = loadSession():andThen(function(session)
				session:startAutosaving()
				session:setData({ coins = 10, inventory = {} })
				session:stopAutosaving()

				jest.advanceTimersByTime(6 * 60 * 1000)

				expect(session:isSaved()).toBe(false)
			end)
			jest.advanceTimersByTime(1000)
			return promise
		end)
	end)

	describe("lock handling", function()
		it("should release lock on unload", function()
			local promise = loadSession():andThen(function(session)
				session:unload()
				jest.advanceTimersByTime(1000)

				local p = loadSession()
				jest.advanceTimersByTime(2 * 60 * 1000)

				return p
			end)
			jest.advanceTimersByTime(1000)
			return expect(promise).resolves.toBeDefined()
		end)

		it("should handle lock loss", function()
			local promise = loadSession():andThen(function(session)
				local updateMock = MockMemoryStoreService.mockHashMapMethod(mockMemory, "UpdateAsync", jest)
				updateMock.mockImplementation(function()
					task.wait(1000)
				end)

				-- Simulate lock loss
				jest.advanceTimersByTime(3 * 60 * 1000)
				expect(session.lockHandle.isLocked()).toBe(false)

				return session:update(function(data)
					data.coins += 10
					return true
				end)
			end)
			jest.advanceTimersByTime(1000)
			return expect(promise).rejects.toEqual("Session is closed")
		end)
	end)

	describe("error handling", function()
		it("should handle DataStore errors during save", function()
			local promise = loadSession():andThen(function(session)
				MockDataStoreService.queueError(mockData, "SetAsync", "503: Service Unavailable", 5)

				session:setData({ coins = 10, inventory = {} })

				local p = session:save()
				jest.advanceTimersByTime(50000)

				return p
			end)
			jest.advanceTimersByTime(1000)
			return expect(promise).rejects.toMatch("503: Service Unavailable")
		end)

		it("should retry on retryable errors", function()
			local attempts = 0
			local promise = loadSession():andThen(function(session)
				local setMock, realSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
				setMock.mockImplementation(function(self, ...)
					attempts += 1
					if attempts <= 2 then
						error("503: Service Unavailable", 0)
					end
					return realSet(self, ...)
				end)

				session:setData({ coins = 10, inventory = {} })

				session:save()
				jest.advanceTimersByTime(30000)

				expect(attempts).toBe(3)
				expect(session:isSaved()).toBe(true)
			end)
			jest.advanceTimersByTime(1000)
			return promise
		end)
	end)
end)
