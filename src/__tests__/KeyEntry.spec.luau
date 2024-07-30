local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Constants = require(ReplicatedStorage.Packages.Lyra.Constants)
local DataStoreInterface = require(ReplicatedStorage.Packages.Lyra.DataStoreInterface)
local HashMapInterface = require(ReplicatedStorage.Packages.Lyra.HashMapInterface)
local KeyEntry = require(ReplicatedStorage.Packages.Lyra.KeyEntry)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local Types = require(ReplicatedStorage.Packages.Lyra.Types)
local splitUtf8String = require(ReplicatedStorage.Packages.Lyra.splitUtf8String)
local Promise = require(ReplicatedStorage.Packages.Promise)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
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
})("KeyEntry with $name", function(services)
	local dataStoreInterface
	local hashMapInterface
	local storeContext
	local keyEntry

	beforeEach(function()
		dataStoreInterface = DataStoreInterface.new(services.dataStoreService)
		hashMapInterface = HashMapInterface.new(MemoryStoreService)
		storeContext = {
			name = `test-{string.sub(HttpService:GenerateGUID(false), 1, 8)}`,
			dataStoreInterface = dataStoreInterface,
			hashMapInterface = hashMapInterface,
			latestVersion = 0,
			migrations = {},
			template = {},
			lockId = HttpService:GenerateGUID(false),
			schema = function(data)
				return typeof(data) == "table"
			end,
			orphanedFileQueue = {
				markFile = jest.fn(),
				markFiles = jest.fn(),
			},
			changedCallbacks = {},
			log = print,
		}
		keyEntry = KeyEntry.new({
			key = "testKey",
			storeContext = storeContext,
		})
	end)

	describe("KeyEntry.new", function()
		it("correctly initializes with default properties", function()
			expect(keyEntry.key).toBe("testKey")
			expect(keyEntry.ctx).toBe(storeContext)
			expect(keyEntry.userIds).toBeNil()
			expect(keyEntry.data).toBeNil()
			expect(keyEntry.metadata).toBeNil()
			expect(keyEntry.version).toBe(0)
			expect(keyEntry.unsavedMutations).toEqual({})
			expect(keyEntry.orphanedFiles).toEqual({})
			expect(keyEntry.currentFile).toBeNil()
		end)

		it("correctly initializes with provided config", function()
			keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
				userIds = { 12345 },
			})

			expect(keyEntry.userIds).toEqual({ 12345 })
		end)
	end)

	describe("KeyEntry:writeLargeFile", function()
		beforeEach(function()
			Constants.MAX_CHUNK_SIZE = 1000
		end)

		afterEach(function()
			Constants.MAX_CHUNK_SIZE = 4_000_000 - 10_000
		end)

		it("correctly handles small files without sharding", function()
			local data = { test = "data" }

			return keyEntry:writeLargeFile(data):andThen(function(file)
				expect(file.data).toBe(data)
				expect(file.shard).toBeNil()
				expect(file.count).toBeNil()
			end)
		end)

		it("correctly shards and writes large files", function()
			local data = string.rep("a", Constants.MAX_CHUNK_SIZE + 1)

			return keyEntry:writeLargeFile(data):andThen(function(file)
				expect(file.shard).never.toBeNil()
				expect(file.count).toBe(2)
			end)
		end)

		it("handles errors during shard writing by marking files as orphaned", function()
			local data = string.rep("a", Constants.MAX_CHUNK_SIZE + 1)

			local n = 0
			local set = dataStoreInterface.set
			dataStoreInterface.set = function(...)
				n += 1
				if n == 2 then
					return Promise.reject("Shard write error")
				end
				return set(...)
			end

			return keyEntry
				:writeLargeFile(data)
				:andThen(function()
					error("Shard write should have errored")
				end)
				:catch(function(err)
					expect(err).toMatch("Shard write error")
					expect(n).toBe(2)
					expect(#keyEntry.orphanedFiles).toBe(1)
					expect(storeContext.orphanedFileQueue.markFile).toHaveBeenCalledTimes(1)
				end)
		end)

		it("validates type of returned file", function()
			local data = string.rep("a", Constants.MAX_CHUNK_SIZE + 1)

			return keyEntry:writeLargeFile(data):andThen(function(file)
				expect(typeof(file.shard)).toBe("string")
				expect(typeof(file.count)).toBe("number")
			end)
		end)

		it("ensures no data loss during sharding and writing", function()
			local testData = {
				foo = "bar",
				baz = { 1, 2, 3 },
				large = string.rep("a", Constants.MAX_CHUNK_SIZE * 2),
			}

			return keyEntry:writeLargeFile(testData):andThen(function(file)
				local shardId = file.shard

				local promises = {}
				for i = 1, file.count do
					table.insert(promises, dataStoreInterface:get(keyEntry.shardScope, `{shardId}-{i}`))
				end
				local shards = Promise.all(promises):expect()

				local reconstructedData = HttpService:JSONDecode(table.concat(shards))
				expect(reconstructedData).toEqual(testData)
			end)
		end)
	end)

	describe("KeyEntry:readLargeFile", function()
		it("correctly reads small files without sharding", function()
			local data = { test = "data" }
			local file = { data = data }

			return keyEntry:readLargeFile(file :: Types.File):andThen(function(readData)
				expect(readData).toBe(data)
			end)
		end)

		it("correctly reads and reassembles large files from shards", function()
			local data = { data = string.rep("a", Constants.MAX_CHUNK_SIZE + 100) }
			local encoded = HttpService:JSONEncode(data)
			local shards = splitUtf8String(encoded, Constants.MAX_CHUNK_SIZE)
			local shardId = HttpService:GenerateGUID(false)
			local file = { shard = shardId, count = 2 } :: Types.File

			return Promise.all({
				dataStoreInterface:set(keyEntry.shardScope, `{shardId}-1`, shards[1]),
				dataStoreInterface:set(keyEntry.shardScope, `{shardId}-2`, shards[2]),
			}):andThen(function()
				local readData = keyEntry:readLargeFile(file):expect()
				expect(readData).toEqual(data)
			end)
		end)

		it("ensures complete and correct reassembly of large files", function()
			local testData = {
				foo = "bar",
				baz = { 1, 2, 3 },
			}
			local data = HttpService:JSONEncode(testData)
			local shardId = HttpService:GenerateGUID(false)
			local file = { shard = shardId, count = 2 } :: Types.File

			return Promise.all({
				dataStoreInterface:set(
					keyEntry.shardScope,
					`{shardId}-1`,
					string.sub(data, 1, Constants.MAX_CHUNK_SIZE)
				),
				dataStoreInterface:set(
					keyEntry.shardScope,
					`{shardId}-2`,
					string.sub(data, Constants.MAX_CHUNK_SIZE + 1)
				),
			}):andThen(function()
				local readData = keyEntry:readLargeFile(file):expect()
				expect(readData).toEqual(testData)
			end)
		end)
	end)

	describe("KeyEntry:readTx", function()
		it("returns committed data if no transaction ID is provided", function()
			local txInfo = {
				txId = nil,
				committedData = { foo = "bar" },
			} :: Types.TxInfo

			return keyEntry:readTx(txInfo):andThen(function(data)
				expect(data).toEqual(txInfo.committedData)
			end)
		end)

		it("ensures correct data is returned for committed and non-committed transactions", function()
			local txInfo1 = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo
			local txInfo2 = {
				txId = "tx456",
				committedData = { hello = "world" },
				txData = { hello = "friend" },
			} :: Types.TxInfo

			return Promise.all({
				dataStoreInterface:set(keyEntry.txScope, "tx123", true),
				dataStoreInterface:set(keyEntry.txScope, "tx456", false),
			}):andThen(function()
				local data1 = keyEntry:readTx(txInfo1):expect()
				local data2 = keyEntry:readTx(txInfo2):expect()

				expect(data1).toEqual(txInfo1.txData)
				expect(data2).toEqual(txInfo2.committedData)
			end)
		end)
	end)

	describe("KeyEntry:updateRecord", function()
		it("correctly writes a record with transaction info", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			return keyEntry:load():andThen(function()
				local record = keyEntry:writeRecord(txInfo):expect()

				expect(record.version).toBe(0)
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
				data = "old data",
			} :: Types.File
			keyEntry.currentFile = toBeOrphaned

			return keyEntry:load():andThen(function()
				keyEntry:writeRecord(txInfo):expect()
				expect(#keyEntry.orphanedFiles).toBe(1)
				expect(keyEntry.orphanedFiles[1]).toBe(toBeOrphaned)
			end)
		end)

		it("handles errors during record writing gracefully", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			dataStoreInterface.set = function(_, _, _)
				return Promise.reject("Record write error")
			end

			return expect(keyEntry:writeRecord(txInfo)).rejects.toBe("Record write error")
		end)

		it("ensures data and metadata are updated correctly", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo
			keyEntry.metadata = { old = "metadata" }

			return keyEntry:load():andThen(function()
				local record = keyEntry:writeRecord(txInfo):expect()
				expect(record.file.data).toEqual(txInfo)
				expect(record.orphanedFiles).toEqual({ keyEntry.currentFile })
			end)
		end)

		it("correctly writes a record with empty table and no currentFile", function()
			return keyEntry:load():andThen(function()
				keyEntry:save():expect()
				keyEntry:updateRecord({}):expect()
				local record = dataStoreInterface:get(keyEntry.recordScope, "testKey"):expect()
				expect(record).toMatchObject(expect.objectContaining({
					version = 0,
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

	describe("KeyEntry:getLock", function()
		it("returns properly formed lock", function()
			local lock = keyEntry:getLock()
			expect(lock).toEqual({
				id = storeContext.lockId,
				expiry = expect.closeTo(DateTime.now().UnixTimestamp + Constants.LOCK_DURATION_SECONDS, 0.1),
			})
		end)
	end)

	describe("KeyEntry:load", function()
		it("correctly locks and loads key", function()
			return keyEntry:load():andThen(function(data)
				expect(data).never.toBeNil()
				expect(keyEntry.locked).toBe(true)
				expect(keyEntry.loaded).toBe(true)
			end)
		end)

		it("verifies and handles lock expiry", function()
			local oldTime = DateTime.now().UnixTimestamp - (Constants.LOCK_DURATION_SECONDS * 2)
			return hashMapInterface
				:set(keyEntry.lockScope, "testKey", {
					id = "other server",
					expiry = oldTime,
				}, 1000)
				:andThen(function()
					local data = keyEntry:load():expect()
					expect(data).never.toBeNil()
					expect(keyEntry.locked).toBe(true)
					expect(keyEntry.loaded).toBe(true)
				end)
		end)

		it("waits for lock to expire correctly", function()
			local now = DateTime.now().UnixTimestamp
			local expiry = now + 2

			return hashMapInterface
				:set(keyEntry.lockScope, keyEntry.key, {
					id = "other server",
					expiry = expiry,
				}, Constants.LOCK_DURATION_SECONDS)
				:andThen(function()
					return keyEntry:load()
				end)
				:andThen(function(data)
					local now2 = DateTime.now().UnixTimestamp
					expect(now2 - now).toBeGreaterThan(1)
					expect(data).never.toBeNil()
					expect(keyEntry.locked).toBe(true)
					expect(keyEntry.loaded).toBe(true)
				end)
		end)

		it("correctly reads and migrates data if necessary", function()
			local testMigrations = {}
			testMigrations[1] = function(data)
				data.migrated = true
				return data
			end
			storeContext.migrations = testMigrations
			storeContext.latestVersion = 1

			local data = {
				foo = "bar",
			}
			return dataStoreInterface
				:set(keyEntry.recordScope, keyEntry.key, {
					version = 0,
					file = { data = { committedData = data } } :: Types.File,
				})
				:andThen(function()
					local record = keyEntry:load():expect()
					expect(record).toEqual({
						foo = "bar",
						migrated = true,
					})
					expect(keyEntry.data).toEqual({
						foo = "bar",
						migrated = true,
					})
				end)
		end)

		it("handles concurrent load attempts", function()
			local p1 = keyEntry:load()
			local p2 = keyEntry:load()
			local e = expect(p2).rejects.toMatch("KeyEntry is already")
			return p1:andThen(function()
				return e
			end)
		end)
	end)

	describe("KeyEntry:get", function()
		it("correctly returns cached data", function()
			return keyEntry:load():andThen(function()
				keyEntry
					:update(function(data)
						data.foo = "bar"
						return true
					end)
					:expect()

				local data = keyEntry:get():expect()
				expect(data).toEqual(keyEntry.data)
			end)
		end)

		it("freezes and deep copies cached data", function()
			return keyEntry:load():andThen(function()
				keyEntry
					:update(function(data)
						data.foo = "bar"
						return true
					end)
					:expect()

				local data = keyEntry:get():expect()
				expect(table.isfrozen(data)).toBe(true)
				expect(data).never.toBe(keyEntry.data)
			end)
		end)
	end)

	describe("KeyEntry:unload", function()
		it("correctly releases lock for the key", function()
			return keyEntry:load():andThen(function()
				keyEntry:unload():expect()

				expect(keyEntry.locked).toBe(false)
				expect(keyEntry.closed).toBe(true)
			end)
		end)

		it("handles cases where the KeyEntry is already closed", function()
			return keyEntry:load():andThen(function()
				keyEntry.closed = true
				return expect(keyEntry:unload()).rejects.toMatch("KeyEntry is closed")
			end)
		end)

		it("ensures proper saving of data", function()
			local data = {
				test = "data",
			}

			return keyEntry:load():andThen(function()
				keyEntry:mutateKey(data)
				keyEntry:unload():expect()

				local record = dataStoreInterface:get(keyEntry.recordScope, "testKey"):expect()

				expect(record.file.data.committedData).toEqual(data)
			end)
		end)

		it("handles concurrent unload attempts gracefully", function()
			return keyEntry:load():andThen(function()
				keyEntry:unload():expect()
				return expect(keyEntry:unload()).rejects.toMatch("KeyEntry is closed")
			end)
		end)
	end)

	describe("KeyEntry:update", function()
		it("correctly applies transform function to key data", function()
			return keyEntry:load():andThen(function()
				keyEntry.data = {
					count = 10,
				}
				local transformFunction = function(data)
					data.count = data.count + 5
					return true
				end

				keyEntry:update(transformFunction):expect()
				expect(keyEntry.data.count).toBe(15)
			end)
		end)

		it("propagates errors from transform function correctly", function()
			return keyEntry:load():andThen(function()
				local transformFunction = function(_)
					error("Transform error")
				end

				return keyEntry:update(transformFunction):catch(function(err)
					expect(err).toMatch("Store:update transformFunction failed:")
					expect(err).toMatch("Transform error")
				end)
			end)
		end)

		it("handles cases where transform function returns false", function()
			local mock, fn = jest.fn(function()
				return false
			end)

			return keyEntry:load():andThen(function()
				keyEntry.data = {
					count = 10,
				}
				keyEntry:update(fn):expect()

				expect(mock).toHaveBeenCalledTimes(1)
				expect(keyEntry.data.count).toBe(10)
			end)
		end)

		it("adheres to the defined schema for data validation", function()
			storeContext.schema = function(data)
				return typeof(data) == "table" and data.value ~= nil
			end

			return keyEntry:load():andThen(function()
				local invalidUpdate = keyEntry
					:update(function(data)
						data.value = nil
						return true
					end)
					:andThen(function()
						error("Invalid update should not be allowed")
					end)

				local validUpdate = keyEntry:update(function(data)
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

			return keyEntry:load():andThen(function()
				keyEntry.data = { value = "initial" }

				local before = keyEntry:getSnapshot()
				keyEntry:update(transformFn):expect()
				local after = keyEntry:getSnapshot()

				expect(mock).toHaveBeenCalledTimes(1)
				expect(before).toEqual(after)
			end)
		end)

		it("handles concurrent update attempts and ensures data consistency", function()
			return keyEntry:load():andThen(function()
				keyEntry.data = { count = 0 }
				keyEntry
					:update(function(data)
						data.count += 1
						return true
					end)
					:expect()
				keyEntry
					:update(function(data)
						data.count += 5
						return true
					end)
					:expect()

				keyEntry:save():expect()

				local record = dataStoreInterface:get(keyEntry.recordScope, "testKey"):expect()
				expect(record.file.data.committedData.count).toBe(6)
			end)
		end)
	end)

	describe("KeyEntry:save", function()
		it("correctly saves data if there are unsaved mutations", function()
			return keyEntry:load():andThen(function()
				keyEntry:mutateKey({
					foo = "bar",
				})

				keyEntry:save():expect()
				local record = dataStoreInterface:get(keyEntry.recordScope, "testKey"):expect()

				expect(record.file.data.committedData).toEqual(keyEntry.data)
				expect(#keyEntry.unsavedMutations).toBe(0)
			end)
		end)

		it("skips save if no unsaved mutations exist", function()
			local mock, fn = jest.fn(function()
				return Promise.resolve()
			end)

			return keyEntry:load():andThen(function()
				keyEntry:save():expect()
				dataStoreInterface.set = fn
				keyEntry:save():expect()
				expect(mock).toHaveBeenCalledTimes(0)
			end)
		end)

		it("commits snapshot after successful save", function()
			return keyEntry:load():andThen(function()
				keyEntry:mutateKey({
					foo = "bar",
				})
				local snapshot = keyEntry:getSnapshot()
				return keyEntry:save():andThen(function()
					expect(keyEntry:isSnapshotCommitted(snapshot)).toBe(true)
				end)
			end)
		end)

		it("handles errors during save operation gracefully", function()
			return keyEntry:load():andThen(function()
				keyEntry:mutateKey({
					foo = "bar",
				})

				dataStoreInterface.set = function()
					return Promise.reject("Save error")
				end

				return expect(keyEntry:save()).rejects.toMatch("Save error")
			end)
		end)
	end)
end)
