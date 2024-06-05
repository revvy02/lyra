local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Constants = require(ReplicatedStorage.Packages.Mix.Constants)
local DataStoreInterface = require(ReplicatedStorage.Packages.Mix.DataStoreInterface)
local KeyEntry = require(ReplicatedStorage.Packages.Mix.KeyEntry)
local MockDataStoreService = require(ReplicatedStorage.Packages.Mix.MockDataStoreService)
local Types = require(ReplicatedStorage.Packages.Mix.Types)
local splitUtf8String = require(ReplicatedStorage.Packages.Mix.splitUtf8String)
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
})("KeyEntry with $name", function(services)
	local dataStoreInterface
	local storeContext
	local keyEntry

	beforeEach(function()
		dataStoreInterface = DataStoreInterface.new(services.dataStoreService)
		storeContext = {
			name = `test-{string.sub(HttpService:GenerateGUID(false), 1, 8)}`,
			dataStoreInterface = dataStoreInterface,
			latestVersion = 1,
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
			expect(keyEntry.version).toBe(1)
			expect(keyEntry.unsavedMutations).toEqual({})
			expect(keyEntry.orphanedFiles).toEqual({})
			expect(keyEntry.currentFile).toBeNil()
		end)

		it("correctly initializes with provided config", function()
			keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
				userIds = { 12345 },
				metadata = { test = "metadata" },
			})

			expect(keyEntry.userIds).toEqual({ 12345 })
			expect(keyEntry.metadata).toEqual({ test = "metadata" })
		end)
	end)

	describe("KeyEntry:writeLargeFile", function()
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

			local data = HttpService:JSONEncode(testData)
			return keyEntry:writeLargeFile(data):andThen(function(file)
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

		it("handles errors during shard reading gracefully", function()
			local shardId = HttpService:GenerateGUID(false)
			local file = { shard = shardId, count = 2 } :: Types.File

			dataStoreInterface.get = function()
				return Promise.reject("Shard read error")
			end

			return keyEntry:readLargeFile(file):catch(function(err)
				expect(err).toMatch("Shard read error")
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

		it("correctly reads transaction data based on transaction ID", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			return dataStoreInterface:set(keyEntry.txScope, "tx123", true):andThen(function()
				local data = keyEntry:readTx(txInfo):expect()
				expect(data).toEqual(txInfo.txData)
			end)
		end)

		it("handles errors during transaction data retrieval", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			dataStoreInterface.get = function(_, _, _)
				return Promise.reject("Transaction read error")
			end

			return keyEntry:readTx(txInfo):catch(function(err)
				expect(err).toBe("Transaction read error")
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

	describe("KeyEntry:writeRecord", function()
		it("correctly writes a record with transaction info", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			return keyEntry:lock():andThen(function()
				local record = keyEntry:writeRecord(txInfo):expect()

				expect(record.version).toBe(1)
				expect(record.lock.id).toBe(storeContext.lockId)
				expect(record.file.data).toEqual(txInfo)
				expect(record.orphanedFiles).toEqual({})
			end)
		end)

		it("handles releaseLock flag correctly", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			return keyEntry:lock():andThen(function()
				local record1 = keyEntry:writeRecord(txInfo, false):expect()
				local record2 = keyEntry:writeRecord(txInfo, true):expect()

				expect(record1.lock.id).never.toBeNil()
				expect(record2.lock.id).toBeNil()
			end)
		end)

		it("ensures lock status is properly verified", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			return dataStoreInterface
				:set(keyEntry.recordScope, "testKey", {
					lock = {
						id = "wrongLockId",
						expiry = DateTime.now().UnixTimestamp + Constants.LOCK_DURATION_SECONDS,
					},
				})
				:andThen(function()
					return expect(keyEntry:writeRecord(txInfo)).rejects.toMatch("Lock violation")
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

			return keyEntry:lock():andThen(function()
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

			dataStoreInterface.update = function(_, _, _)
				return Promise.reject("Record write error")
			end

			return keyEntry:writeRecord(txInfo):catch(function(err)
				expect(err).toBe("Record write error")
			end)
		end)

		it("ensures data and metadata are updated correctly", function()
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo
			keyEntry.metadata = { old = "metadata" }

			return keyEntry:lock():andThen(function()
				local record = keyEntry:writeRecord(txInfo):expect()
				expect(record.file.data).toEqual(txInfo)
				expect(record.orphanedFiles).toEqual({ keyEntry.currentFile })
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

	describe("KeyEntry:lock", function()
		it("correctly acquires lock for the key", function()
			return keyEntry
				:lock()
				:andThen(function(data)
					expect(data).never.toBeNil()
				end)
				:catch(error)
		end)

		it("verifies and handles lock expiry", function()
			local oldTime = DateTime.now().UnixTimestamp - (Constants.LOCK_DURATION_SECONDS * 2)
			return dataStoreInterface
				:set(keyEntry.recordScope, "testKey", {
					lock = {
						id = "someOtherLock",
						expiry = oldTime,
					},
				})
				:andThen(function()
					local data = keyEntry:lock():expect()
					expect(data).never.toBeNil()
				end)
		end)

		it("correctly reads and migrates data if necessary", function()
			local testMigrations = {}
			testMigrations[2] = function(data)
				data.migrated = true
				return data
			end
			storeContext.migrations = testMigrations
			storeContext.latestVersion = 2

			local data = {
				foo = "bar",
			}
			return dataStoreInterface
				:set(keyEntry.recordScope, "testKey", {
					version = 1,
					lock = {},
					file = { data = { committedData = data } } :: Types.File,
				})
				:andThen(function()
					local record = keyEntry:lock():expect()
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

		it("handles concurrent lock attempts and ensures data consistency", function()
			return keyEntry:lock():andThen(function(data)
				expect(data).never.toBeNil()
				return expect(keyEntry:lock()).rejects.toMatch("KeyEntry is already locked")
			end)
		end)
	end)

	describe("KeyEntry:get", function()
		it("correctly returns cached data", function()
			return keyEntry:lock():andThen(function()
				keyEntry
					:update(function(data)
						data.foo = "bar"
						return data
					end)
					:expect()

				local data = keyEntry:get():expect()
				expect(data).toEqual(keyEntry.data)
			end)
		end)

		it("freezes and deep copies cached data", function()
			return keyEntry:lock():andThen(function()
				keyEntry
					:update(function(data)
						data.foo = "bar"
						return data
					end)
					:expect()

				local data = keyEntry:get():expect()
				expect(table.isfrozen(data)).toBe(true)
				expect(data).never.toBe(keyEntry.data)
			end)
		end)
	end)

	describe("KeyEntry:unlock", function()
		it("correctly releases lock for the key", function()
			local data = {
				test = "data",
			}
			return keyEntry:lock():andThen(function()
				keyEntry.data = data
				keyEntry:unlock():expect()

				local record = dataStoreInterface:get(keyEntry.recordScope, "testKey"):expect()

				expect(record.lock).toEqual({})
				expect(record.file.data.committedData).toEqual(data)
			end)
		end)

		it("handles cases where the KeyEntry is already closed", function()
			return keyEntry:lock():andThen(function()
				keyEntry.closed = true
				return expect(keyEntry:unlock()).rejects.toMatch("KeyEntry is closed")
			end)
		end)

		it("ensures proper cleanup and saving of data", function()
			local data = {
				test = "data",
			}

			return keyEntry:lock():andThen(function()
				keyEntry:mutateKey(data)
				keyEntry:unlock():expect()

				local record = dataStoreInterface:get(keyEntry.recordScope, "testKey"):expect()

				expect(record.file.data.committedData).toEqual(data)
			end)
		end)

		it("handles concurrent unlock attempts gracefully", function()
			return keyEntry:lock():andThen(function()
				keyEntry:unlock():expect()
				return expect(keyEntry:unlock()).rejects.toMatch("KeyEntry is closed")
			end)
		end)
	end)

	describe("KeyEntry:update", function()
		it("correctly applies transform function to key data", function()
			return keyEntry:lock():andThen(function()
				keyEntry.data = {
					count = 10,
				}
				local transformFunction = function(data)
					data.count = data.count + 5
					return data
				end

				keyEntry:update(transformFunction):expect()
				expect(keyEntry.data.count).toBe(15)
			end)
		end)

		it("propagates errors from transform function correctly", function()
			return keyEntry:lock():andThen(function()
				local transformFunction = function(_)
					error("Transform error")
				end

				return keyEntry:update(transformFunction):catch(function(err)
					expect(err).toMatch("Store:update transformFunction failed:")
					expect(err).toMatch("Transform error")
				end)
			end)
		end)

		it("handles cases where transform function returns nil", function()
			local mock, fn = jest.fn(function()
				return nil
			end)

			return keyEntry:lock():andThen(function()
				keyEntry.data = {
					count = 10,
				}
				keyEntry:update(fn):expect()

				expect(mock).toHaveBeenCalledTimes(1)
				expect(keyEntry:getSnapshot()).toEqual({})
				expect(keyEntry.data.count).toBe(10)
			end)
		end)

		it("adheres to the defined schema for data validation", function()
			storeContext.schema = function(data)
				return typeof(data) == "table" and data.value ~= nil
			end

			return keyEntry:lock():andThen(function()
				local invalidUpdate = keyEntry
					:update(function(data)
						data = 123 -- Invalid update according to schema
						return data
					end)
					:andThen(function()
						error("Invalid update should not be allowed")
					end)
					:catch(function(err)
						return Promise.resolve(err)
					end)
				local validUpdate = keyEntry:update(function(data)
					data = { value = "valid" }
					return data
				end)

				return Promise.all({ invalidUpdate, validUpdate }):andThen(function(results)
					local invalidUpdateResult = results[1]

					expect(invalidUpdateResult).toMatch("schema validation failed")
					expect(results[2]).toBeNil()
				end)
			end)
		end)

		it("skips update if data is unchanged after applying transform function", function()
			local mock, transformFn = jest.fn(function(data)
				return data
			end)

			return keyEntry:lock():andThen(function()
				keyEntry.data = { value = "initial" }

				local before = keyEntry:getSnapshot()
				keyEntry:update(transformFn):expect()
				local after = keyEntry:getSnapshot()

				expect(mock).toHaveBeenCalledTimes(1)
				expect(before).toEqual(after)
			end)
		end)

		it("handles concurrent update attempts and ensures data consistency", function()
			return keyEntry:lock():andThen(function()
				keyEntry.data = { count = 0 }
				keyEntry
					:update(function(data)
						data.count = data.count + 1
						return data
					end)
					:expect()
				keyEntry
					:update(function(data)
						data.count = data.count + 5
						return data
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
			return keyEntry:lock():andThen(function()
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
			local updateMock, fn = jest.fn()

			return keyEntry:lock():andThen(function()
				dataStoreInterface.update = fn
				keyEntry:save():expect()
				expect(updateMock).toHaveBeenCalledTimes(0)
			end)
		end)

		it("commits snapshot after successful save", function()
			return keyEntry:lock():andThen(function()
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
			return keyEntry:lock():andThen(function()
				keyEntry:mutateKey({
					foo = "bar",
				})

				dataStoreInterface.update = function()
					return Promise.reject("Save error")
				end

				return expect(keyEntry:save()).rejects.toMatch("Save error")
			end)
		end)
	end)
end)
