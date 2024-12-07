local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Constants = require(ReplicatedStorage.Packages.Lyra.Constants)
local DataStoreInterface = require(ReplicatedStorage.Packages.Lyra.DataStoreInterface)
local HashMapInterface = require(ReplicatedStorage.Packages.Lyra.HashMapInterface)
local Session = require(ReplicatedStorage.Packages.Lyra.Session)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local Types = require(ReplicatedStorage.Packages.Lyra.Types)
local Promise = require(ReplicatedStorage.Packages.Promise)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local jest = JestGlobals.jest

describe.each({
	{
		name = "MockDataStoreService",
		dataStoreService = MockDataStoreService.createMockService(),
	},
	{
		name = "DataStoreService",
		dataStoreService = game:GetService("DataStoreService"),
	},
})("Session with $name", function(services)
	local dataStoreInterface
	local hashMapInterface
	local storeContext

	local function getSession()
		return Session.load({
			key = "testKey",
			storeContext = storeContext,
		})
	end

	beforeEach(function()
		dataStoreInterface = DataStoreInterface.new(services.dataStoreService)
		hashMapInterface = HashMapInterface.new(MemoryStoreService)
		local name = `test-{string.sub(HttpService:GenerateGUID(false), 1, 8)}`
		storeContext = {
			name = name,
			dataStoreInterface = dataStoreInterface,
			hashMapInterface = hashMapInterface,
			migrationSteps = {},
			template = {},
			schema = function(data)
				return typeof(data) == "table"
			end,
			orphanedFileQueue = {
				markFile = jest.fn(),
				markFiles = jest.fn(),
			},
			changedCallbacks = {},
			log = print,
			recordScope = `{Constants.RECORD_SCOPE}/{name}`,
			shardScope = `{Constants.SHARD_SCOPE}/{name}`,
			lockScope = `{Constants.LOCK_SCOPE}/{name}`,
			txScope = `{Constants.TX_SCOPE}/{name}`,
		}
	end)

	describe("Session.load", function()
		it("correctly initializes with default properties", function()
			return getSession():andThen(function(session)
				expect(session.key).toBe("testKey")
				expect(session.ctx).toBe(storeContext)
				expect(session.userIds).toBeNil()
				expect(session.data).toEqual({})
				expect(session.appliedMigrations).toEqual({})
				expect(session.changeSet).never.toBeNil()
				expect(session.orphanedFiles).toEqual({})
				expect(session.currentFile).toBeNil()
			end)
		end)

		it("correctly initializes with provided config", function()
			return Session.load({
				key = "testKey",
				storeContext = storeContext,
				userIds = { 12345 },
			}):andThen(function(session)
				expect(session.userIds).toEqual({ 12345 })
			end)
		end)
	end)

	describe("Session:updateRecord/writeRecord", function()
		it("correctly writes a record with transaction info", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			return getSession():andThen(function(session)
				local record = session:writeRecord(txInfo):expect()

				expect(record.appliedMigrations).toEqual({})
				expect(record.file.data).toEqual(txInfo)
				expect(record.orphanedFiles).toEqual({})
			end)
		end)

		it("tracks and updates orphaned files accurately", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo
			local toBeOrphaned = {
				shard = "a",
				count = 2,
			} :: Types.File

			return getSession():andThen(function(session)
				session.currentFile = toBeOrphaned
				session:writeRecord(txInfo):expect()
				expect(#session.orphanedFiles).toBe(1)
				expect(session.orphanedFiles[1]).toBe(toBeOrphaned)
			end)
		end)

		it("handles errors during record writing gracefully", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			return getSession():andThen(function(session)
				dataStoreInterface.set = function(_, _, _)
					return Promise.reject("Record write error")
				end

				return expect(session:writeRecord(txInfo)).rejects.toBe("Record write error")
			end)
		end)

		it("ensures data and metadata are updated correctly", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			return getSession():andThen(function(session)
				local record = session:writeRecord(txInfo):expect()
				expect(record.file.data).toEqual(txInfo)
				expect(record.orphanedFiles).toEqual({ session.currentFile })
			end)
		end)

		it("correctly writes a record with empty table and no currentFile", function()
			return getSession():andThen(function(session)
				session:save():expect()
				session:updateRecord({}):expect()
				local record = dataStoreInterface:get(storeContext.recordScope, "testKey"):expect()
				expect(record).toMatchObject(expect.objectContaining({
					appliedMigrations = {},
					file = {
						data = {
							txId = nil,
							committedData = expect.any("table"),
							txData = nil,
						},
					},
					orphanedFiles = {},
				}))
			end)
		end)
	end)

	describe("Session:load", function()
		it("correctly locks and loads key", function()
			return getSession():andThen(function(session)
				local data = session:get():expect()
				expect(data).never.toBeNil()
			end)
		end)

		it("waits for lock to expire correctly", function()
			local now = DateTime.now().UnixTimestamp

			local handle = hashMapInterface:set(storeContext.lockScope, "testKey", "other server", 2)
			return handle.promise:andThen(getSession):andThen(function(session)
				local data = session:get():expect()
				local now2 = DateTime.now().UnixTimestamp
				expect(now2 - now).toBeGreaterThan(0.9)
				expect(data).never.toBeNil()
			end)
		end)

		it("correctly reads and migrates data if necessary", function()
			local testMigrations = {}
			testMigrations[1] = {
				name = "test migrate",
				apply = function(data)
					data.migrated = true
				end,
			}
			storeContext.migrationSteps = testMigrations

			local data = {
				foo = "bar",
			}
			return dataStoreInterface
				:set(storeContext.recordScope, "testKey", {
					appliedMigrations = {},
					file = { data = { committedData = data } } :: Types.File,
				})
				:andThen(getSession)
				:andThen(function(session)
					expect(session.data).toEqual({
						foo = "bar",
						migrated = true,
					})
				end)
		end)
	end)

	describe("Session:get", function()
		it("correctly returns cached data", function()
			return getSession():andThen(function(session)
				session
					:update(function(data)
						data.foo = "bar"
						return true
					end)
					:expect()

				local data = session:get():expect()
				expect(data).toEqual(session.data)
			end)
		end)

		it("freezes and deep copies cached data", function()
			return getSession():andThen(function(session)
				session
					:update(function(data)
						data.foo = "bar"
						return true
					end)
					:expect()

				local data = session:get():expect()
				expect(table.isfrozen(data)).toBe(true)
				expect(data).never.toBe(session.data)
			end)
		end)
	end)

	describe("Session:unload", function()
		it("correctly releases lock for the key", function()
			return getSession():andThen(function(session)
				session:unload():expect()

				expect(session.lockHandle.isLocked()).toBe(false)
				expect(session.closed).toBe(true)
			end)
		end)

		it("ensures proper saving of data", function()
			local data = {
				test = "data",
			}

			return getSession():andThen(function(session)
				session:mutateKey(data)
				session:unload():expect()

				local record = dataStoreInterface:get(storeContext.recordScope, "testKey"):expect()

				expect(record.file.data.committedData).toEqual(data)
			end)
		end)
	end)

	describe("Session:update", function()
		it("correctly applies transform function to key data", function()
			return getSession():andThen(function(session)
				session.data = {
					count = 10,
				}
				local transformFunction = function(data)
					data.count = data.count + 5
					return true
				end

				session:update(transformFunction):expect()
				expect(session.data.count).toBe(15)
			end)
		end)

		it("propagates errors from transform function correctly", function()
			return getSession():andThen(function(session)
				local transformFunction = function(_)
					error("Transform error")
				end

				return session:update(transformFunction):catch(function(err)
					expect(err).toMatch("transformFunction failed:")
					expect(err).toMatch("Transform error")
				end)
			end)
		end)

		it("handles cases where transform function returns false", function()
			local mock, fn = jest.fn(function()
				return false
			end)

			return getSession():andThen(function(session)
				session.data = {
					count = 10,
				}
				session:update(fn):expect()

				expect(mock).toHaveBeenCalledTimes(1)
				expect(session.data.count).toBe(10)
			end)
		end)

		it("adheres to the defined schema for data validation", function()
			storeContext.schema = function(data)
				return typeof(data) == "table" and data.value ~= nil
			end

			return getSession():andThen(function(session)
				local invalidUpdate = session
					:update(function(data)
						data.value = nil
						return true
					end)
					:andThen(function()
						error("Invalid update should not be allowed")
					end)

				local validUpdate = session:update(function(data)
					data.value = "valid"
					return true
				end)

				local e = expect(invalidUpdate).rejects.toMatch("schema validation failed")
				return validUpdate:andThenReturn(e)
			end)
		end)

		it("skips update if data is unchanged after applying transform function", function()
			local mock, transformFn = jest.fn(function()
				return true
			end)

			return getSession():andThen(function(session)
				session.data = { value = "initial" }

				local before = table.clone(session.changeSet)
				session:update(transformFn):expect()
				local after = table.clone(session.changeSet)

				expect(mock).toHaveBeenCalledTimes(1)
				expect(before).toEqual(after)
			end)
		end)

		it("handles concurrent update attempts and ensures data consistency", function()
			return getSession():andThen(function(session)
				session.data = { count = 0 }
				session
					:update(function(data)
						data.count += 1
						return true
					end)
					:expect()
				session
					:update(function(data)
						data.count += 5
						return true
					end)
					:expect()

				session:save():expect()

				local record = dataStoreInterface:get(storeContext.recordScope, "testKey"):expect()
				expect(record.file.data.committedData.count).toBe(6)
			end)
		end)
	end)

	describe("Session:save", function()
		it("correctly saves data if there are unsaved changes", function()
			return getSession():andThen(function(session)
				session:mutateKey({
					foo = "bar",
				})

				session:save():expect()
				local record = dataStoreInterface:get(storeContext.recordScope, "testKey"):expect()

				expect(record.file.data.committedData).toEqual(session.data)
				expect((next(session.changeSet))).toBeNil()
			end)
		end)

		it("skips save if no unsaved changes exist", function()
			local mock, fn = jest.fn(function()
				return Promise.resolve()
			end)

			return getSession():andThen(function(session)
				session:save():expect()
				dataStoreInterface.set = fn
				session:save():expect()
				expect(mock).toHaveBeenCalledTimes(0)
			end)
		end)

		it("tracks changes correctly", function()
			return getSession():andThen(function(session)
				session:mutateKey({
					foo = "bar",
				})
				expect((next(session.changeSet))).never.toBeNil()
				return session:save():andThen(function()
					expect(session.changeSet).toEqual({})
				end)
			end)
		end)

		it("handles errors during save operation gracefully", function()
			return getSession():andThen(function(session)
				session:mutateKey({
					foo = "bar",
				})

				dataStoreInterface.set = function()
					return Promise.reject("Save error")
				end

				return expect(session:save()).rejects.toMatch("Save error")
			end)
		end)
	end)
end)
