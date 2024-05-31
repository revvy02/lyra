local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Constants = require(ReplicatedStorage.Packages.Mix.Constants)
local MockInterface = require(ReplicatedStorage.Packages.Mix.DataStoreInterface.MockInterface)
local KeyEntry = require(ReplicatedStorage.Packages.Mix.KeyEntry)
local Types = require(ReplicatedStorage.Packages.Mix.Types)
local splitUtf8String = require(ReplicatedStorage.Packages.Mix.splitUtf8String)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local jest = JestGlobals.jest

local function createMockDataStoreKeyInfo()
	local currentTime = DateTime.now()
	local self
	self = {
		_metadata = {},
		_userIds = {},
		CreatedTime = currentTime,
		UpdatedTime = currentTime,
		Version = HttpService:GenerateGUID(false),
		GetMetadata = function()
			return self._metadata
		end,
		GetUserIds = function()
			return self._userIds
		end,
	}
	return self
end

describe("KeyEntry", function()
	local mockDataStoreInterface
	local storeContext

	beforeEach(function()
		mockDataStoreInterface = MockInterface.new({ yields = false })
		storeContext = {
			dataStoreInterface = mockDataStoreInterface,
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
	end)

	describe("KeyEntry.new", function()
		it("correctly initializes with default properties", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			expect(keyEntry.key).toBe("testKey")
			expect(keyEntry.ctx).toBe(storeContext)
			expect(keyEntry.userIds).toBe(nil)
			expect(keyEntry.data).toBe(nil)
			expect(keyEntry.metadata).toBe(nil)
			expect(keyEntry.version).toBe(1)
			expect(keyEntry.unsavedMutations).toEqual({})
			expect(keyEntry.orphanedFiles).toEqual({})
			expect(keyEntry.currentFile).toBe(nil)
		end)

		it("correctly initializes with provided config", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
				userIds = { 12345 },
			})

			expect(keyEntry.userIds).toEqual({ 12345 })
		end)

		it("handles missing or nil userIds gracefully", function()
			local keyEntry1 = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local keyEntry2 = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
				userIds = nil,
			})

			expect(keyEntry1.userIds).toBe(nil)
			expect(keyEntry2.userIds).toBe(nil)
		end)
	end)

	describe("KeyEntry:writeLargeFile", function()
		it("correctly handles small files without sharding", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local data = { test = "data" }

			local file = keyEntry:writeLargeFile(data):expect()

			expect(file.data).toBe(data)
			expect(file.shard).toBe(nil)
			expect(file.count).toBe(nil)
		end)

		it("correctly shards and writes large files", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local data = string.rep("a", Constants.MAX_CHUNK_SIZE + 1)

			local file = keyEntry:writeLargeFile(data):expect()

			expect(file.shard).toBeDefined()
			expect(file.count).toBe(2)
		end)

		it("handles errors during shard writing by marking files as orphaned", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local data = string.rep("a", Constants.MAX_CHUNK_SIZE + 1)

			mockDataStoreInterface.set = function(_, _, _, _, _, _)
				return Promise.reject("Shard write error")
			end

			keyEntry:writeLargeFile(data):catch(function() end):expect()

			expect(#keyEntry.orphanedFiles).toBe(1)
			expect(storeContext.orphanedFileQueue.markFile).toHaveBeenCalledTimes(1)
		end)

		it("ensures orphaned files are tracked correctly", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local data1 = string.rep("a", Constants.MAX_CHUNK_SIZE + 1)
			local data2 = string.rep("b", Constants.MAX_CHUNK_SIZE * 3)

			mockDataStoreInterface.set = function(_, _, key, _, _, _)
				if key:match("%-1$") then
					return Promise.reject("Shard write error")
				end
				return Promise.resolve()
			end

			keyEntry:writeLargeFile(data1):catch(function() end):expect()
			local file2 = keyEntry:writeLargeFile(data2):catch(function() end):expect()

			expect(#keyEntry.orphanedFiles).toBe(2)
			expect(storeContext.orphanedFileQueue.markFile).toHaveBeenCalledTimes(2)
			expect(keyEntry.currentFile).toEqual(file2)
		end)

		it("validates type of returned file", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local data = string.rep("a", Constants.MAX_CHUNK_SIZE + 1)

			local file = keyEntry:writeLargeFile(data):expect()

			expect(typeof(file.shard)).toBe("string")
			expect(typeof(file.count)).toBe("number")
		end)

		it("ensures no data loss during sharding and writing", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local testData = {
				foo = "bar",
				baz = { 1, 2, 3 },
				large = string.rep("a", Constants.MAX_CHUNK_SIZE * 2),
			}

			local data = HttpService:JSONEncode(testData)
			local file = keyEntry:writeLargeFile(data):expect()
			local shardId = file.shard

			local promises = {}
			for i = 1, file.count do
				table.insert(promises, mockDataStoreInterface:get(Constants.SHARD_SCOPE, `{shardId}-{i}`))
			end

			Promise.all(promises)
				:andThen(function(shards)
					local reconstructedData = HttpService:JSONDecode(table.concat(shards))
					expect(reconstructedData).toEqual(testData)
				end)
				:expect()
		end)
	end)

	describe("KeyEntry:readLargeFile", function()
		it("correctly reads small files without sharding", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local data = { test = "data" }
			local file = { data = data }

			local readData = keyEntry:readLargeFile(file :: Types.File):expect()

			expect(readData).toBe(data)
		end)

		it("correctly reads and reassembles large files from shards", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local data = { data = string.rep("a", Constants.MAX_CHUNK_SIZE + 100) }
			local encoded = HttpService:JSONEncode(data)
			local shards = splitUtf8String(encoded, Constants.MAX_CHUNK_SIZE)
			local shardId = HttpService:GenerateGUID(false)
			local file = { shard = shardId, count = 2 } :: Types.File

			mockDataStoreInterface._store[Constants.SHARD_SCOPE] = {
				[`{shardId}-1`] = { value = shards[1] },
				[`{shardId}-2`] = { value = shards[2] },
			}

			local readData = keyEntry:readLargeFile(file):expect()
			expect(readData).toEqual(data)
		end)

		it("handles errors during shard reading gracefully", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local shardId = HttpService:GenerateGUID(false)
			local file = { shard = shardId, count = 2 } :: Types.File

			mockDataStoreInterface.get = function(_, _, _)
				return Promise.reject("Shard read error")
			end

			local readData = keyEntry
				:readLargeFile(file)
				:catch(function(err)
					return err
				end)
				:expect()

			expect(readData).toBe("Shard read error")
		end)

		it("ensures complete and correct reassembly of large files", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local testData = {
				foo = "bar",
				baz = { 1, 2, 3 },
			}
			local data = HttpService:JSONEncode(testData)
			local shardId = HttpService:GenerateGUID(false)
			local file = { shard = shardId, count = 2 } :: Types.File
			mockDataStoreInterface._store[Constants.SHARD_SCOPE] = {
				[`{shardId}-1`] = { value = string.sub(data, 1, Constants.MAX_CHUNK_SIZE) },
				[`{shardId}-2`] = { value = string.sub(data, Constants.MAX_CHUNK_SIZE + 1) },
			}

			local readData = keyEntry:readLargeFile(file):expect()

			expect(readData).toEqual(testData)
		end)
	end)

	describe("KeyEntry:readTx", function()
		it("returns committed data if no transaction ID is provided", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = nil,
				committedData = { foo = "bar" },
			} :: Types.TxInfo

			local data = keyEntry:readTx(txInfo):expect()

			expect(data).toEqual(txInfo.committedData)
		end)

		it("correctly reads transaction data based on transaction ID", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			mockDataStoreInterface._store[Constants.TX_SCOPE] = {
				["tx123"] = { value = true },
			}
			local data = keyEntry:readTx(txInfo):expect()

			expect(data).toEqual(txInfo.txData)
		end)

		it("handles errors during transaction data retrieval", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			mockDataStoreInterface.get = function(_, _, _)
				return Promise.reject("Transaction read error")
			end

			local data = keyEntry
				:readTx(txInfo)
				:catch(function(err)
					return err
				end)
				:expect()

			expect(data).toBe("Transaction read error")
		end)

		it("ensures correct data is returned for committed and non-committed transactions", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
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

			mockDataStoreInterface._store[Constants.TX_SCOPE] = {
				["tx123"] = { value = true },
				["tx456"] = { value = false },
			}

			local data1 = keyEntry:readTx(txInfo1):expect()
			local data2 = keyEntry:readTx(txInfo2):expect()

			expect(data1).toEqual(txInfo1.txData)
			expect(data2).toEqual(txInfo2.committedData)
		end)
	end)

	describe("KeyEntry:writeRecord", function()
		it("correctly writes a record with transaction info", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo
			mockDataStoreInterface._store[Constants.RECORD_SCOPE] = {}

			keyEntry:lock():expect()
			local record = keyEntry:writeRecord(txInfo):expect()

			expect(record.version).toBe(1)
			expect(record.lock.id).toBe(storeContext.lockId)
			expect(record.file.data).toEqual(txInfo)
			expect(record.orphanedFiles).toEqual({})
		end)

		it("handles releaseLock flag correctly", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo
			mockDataStoreInterface._store[Constants.RECORD_SCOPE] = {}

			keyEntry:lock():expect()
			local record1 = keyEntry:writeRecord(txInfo, false):expect()
			local record2 = keyEntry:writeRecord(txInfo, true):expect()

			expect(record1.lock.id).toBeDefined()
			expect(record2.lock.id).toBe(nil)
		end)

		it("ensures lock status is properly verified", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			mockDataStoreInterface.update = function(_, _, _)
				return Promise.resolve({
					lock = {
						id = "wrongLockId",
					},
				})
			end

			local result = keyEntry
				:writeRecord(txInfo)
				:catch(function(err)
					return err
				end)
				:expect()

			expect(result).toBe("Lock violation")
		end)

		it("tracks and updates orphaned files accurately", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo
			local toBeOrphaned = {
				data = "old data",
			} :: Types.File
			keyEntry.currentFile = toBeOrphaned
			mockDataStoreInterface._store[Constants.RECORD_SCOPE] = {}

			keyEntry:lock():expect()
			keyEntry:writeRecord(txInfo):expect()

			expect(#keyEntry.orphanedFiles).toBe(1)
			expect(keyEntry.orphanedFiles[1]).toBe(toBeOrphaned)
		end)

		it("handles errors during record writing gracefully", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo

			mockDataStoreInterface.update = function(_, _, _)
				return Promise.reject("Record write error")
			end

			local result = keyEntry
				:writeRecord(txInfo)
				:catch(function(err)
					return err
				end)
				:expect()

			expect(result).toBe("Record write error")
		end)

		it("ensures data and metadata are updated correctly", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local txInfo = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			} :: Types.TxInfo
			keyEntry.metadata = { old = "metadata" }
			mockDataStoreInterface._store[Constants.RECORD_SCOPE] = {}

			keyEntry:lock():expect()
			local record = keyEntry:writeRecord(txInfo):expect()

			expect(record.file.data).toEqual(txInfo)
			expect(record.orphanedFiles).toEqual({ keyEntry.currentFile })
		end)
	end)

	describe("KeyEntry:getLock", function()
		it("returns a lock with correct ID and expiry time", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			local lock = keyEntry:getLock()

			expect(lock.id).toBe(storeContext.lockId)
			expect(lock.expiry).toBeGreaterThan(DateTime.now().UnixTimestamp)
		end)
	end)

	describe("KeyEntry:getSnapshot", function()
		it("returns a correct snapshot of unsaved mutations", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			keyEntry.unsavedMutations = {
				["mutation1"] = true,
				["mutation2"] = true,
			}

			local snapshot = keyEntry:getSnapshot()

			expect(snapshot).toEqual(keyEntry.unsavedMutations)
		end)

		it("ensures snapshot accurately reflects current unsaved mutations", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			keyEntry.unsavedMutations = {
				["mutation1"] = true,
				["mutation2"] = true,
			}

			local snapshot1 = keyEntry:getSnapshot()

			keyEntry.unsavedMutations["mutation3"] = true

			local snapshot2 = keyEntry:getSnapshot()

			expect(snapshot1).toEqual({
				["mutation1"] = true,
				["mutation2"] = true,
			})
			expect(snapshot2).toEqual({
				["mutation1"] = true,
				["mutation2"] = true,
				["mutation3"] = true,
			})
		end)
	end)

	describe("KeyEntry:isSnapshotCommitted", function()
		it("correctly identifies committed snapshots", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			keyEntry.unsavedMutations = {
				["mutation1"] = true,
				["mutation2"] = true,
			}

			local snapshot1 = {
				["mutation3"] = true,
			}
			local snapshot2 = {
				["mutation1"] = true,
			}

			local isCommitted1 = keyEntry:isSnapshotCommitted(snapshot1)
			local isCommitted2 = keyEntry:isSnapshotCommitted(snapshot2)

			expect(isCommitted1).toBe(true)
			expect(isCommitted2).toBe(false)
		end)

		it("handles cases with empty and non-empty snapshots", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			keyEntry.unsavedMutations = {
				["mutation1"] = true,
			}

			local snapshot1 = {}
			local snapshot2 = {
				["mutation1"] = true,
			}

			local isCommitted1 = keyEntry:isSnapshotCommitted(snapshot1)
			local isCommitted2 = keyEntry:isSnapshotCommitted(snapshot2)

			expect(isCommitted1).toBe(true)
			expect(isCommitted2).toBe(false)
		end)

		it("ensures accurate comparison of snapshots", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.unsavedMutations = {
				["mutation1"] = true,
				["mutation2"] = true,
				["mutation3"] = true,
			}

			local snapshot1 = {
				["mutation1"] = true,
				["mutation2"] = true,
			}

			local snapshot2 = {
				["mutation1"] = true,
				["mutation3"] = true,
			}

			local isCommitted1 = keyEntry:isSnapshotCommitted(snapshot1)
			local isCommitted2 = keyEntry:isSnapshotCommitted(snapshot2)

			expect(isCommitted1).toBe(false)
			expect(isCommitted2).toBe(false)
		end)
	end)

	describe("KeyEntry:commitSnapshot", function()
		it("correctly commits the provided snapshot", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.unsavedMutations = {
				["mutation1"] = true,
				["mutation2"] = true,
				["mutation3"] = true,
			}

			local snapshot = {
				["mutation1"] = true,
				["mutation3"] = true,
			}

			keyEntry:commitSnapshot(snapshot)

			expect(keyEntry.unsavedMutations).toEqual({
				["mutation2"] = true,
			})
		end)

		it("ensures unsaved mutations are updated accurately", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			keyEntry.unsavedMutations = {
				["mutation1"] = true,
				["mutation2"] = true,
			}

			local snapshot1 = {
				["mutation1"] = true,
			}

			keyEntry:commitSnapshot(snapshot1)

			expect(keyEntry.unsavedMutations).toEqual({ ["mutation2"] = true })

			keyEntry.unsavedMutations = {
				["mutation3"] = true,
				["mutation4"] = true,
			}

			local snapshot2 = {
				["mutation3"] = true,
			}

			keyEntry:commitSnapshot(snapshot2)

			expect(keyEntry.unsavedMutations).toEqual({ ["mutation4"] = true })
		end)
	end)

	describe("KeyEntry:isSaved", function()
		it("correctly identifies if there are no unsaved mutations", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local isSaved1 = keyEntry:isSaved()

			keyEntry.unsavedMutations = {
				["mutation1"] = true,
			}
			local isSaved2 = keyEntry:isSaved()

			keyEntry:commitSnapshot({ ["mutation1"] = true })
			local isSaved3 = keyEntry:isSaved()

			expect(isSaved1).toBe(true)
			expect(isSaved2).toBe(false)
			expect(isSaved3).toBe(true)
		end)
	end)

	describe("KeyEntry:mutateKey", function()
		it("correctly mutates key data and adds a new unsaved mutation", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			local newData = {
				foo = "newBar",
			}
			keyEntry:mutateKey(newData)

			expect(keyEntry.data).toEqual(newData)
			expect(Sift.Set.count(keyEntry.unsavedMutations)).toBeGreaterThan(0)

			keyEntry:mutateKey(123)
			expect(keyEntry.data).toBe(123)
			expect(Sift.Set.count(keyEntry.unsavedMutations)).toBeGreaterThan(1)
		end)

		it("handles various data types for mutation", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			keyEntry:mutateKey({ foo = "bar" })
			expect(typeof(keyEntry.data)).toBe("table")

			keyEntry:mutateKey("test string")
			expect(typeof(keyEntry.data)).toBe("string")

			keyEntry:mutateKey(123)
			expect(typeof(keyEntry.data)).toBe("number")

			keyEntry:mutateKey(true)
			expect(typeof(keyEntry.data)).toBe("boolean")
		end)

		it("ensures unique mutation IDs for each call", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			keyEntry:mutateKey({})
			keyEntry:mutateKey({})

			local ids = {}
			for id in keyEntry.unsavedMutations do
				expect(ids[id]).toBe(nil)
				ids[id] = true
			end
		end)
	end)

	describe("KeyEntry:migrateData", function()
		it("correctly migrates data through multiple versions", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.version = 1

			local migrations = {}
			migrations[2] = function(data)
				data.foo = "bar"
				return data
			end
			migrations[3] = function(data)
				data.baz = { 1, 2, 3 }
				return data
			end
			storeContext.migrations = migrations
			storeContext.latestVersion = 3

			local data = keyEntry:migrateData({}):expect()

			expect(data).toEqual({
				foo = "bar",
				baz = { 1, 2, 3 },
			})
		end)

		it("handles missing migration steps gracefully", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.version = 1

			local migrations = {}
			migrations[3] = function(data)
				data.baz = { 1, 2, 3 }
				return data
			end
			storeContext.migrations = migrations
			storeContext.latestVersion = 3

			local data = keyEntry:migrateData({ foo = "bar" }):expect()

			expect(data).toEqual({
				foo = "bar",
				baz = { 1, 2, 3 },
			})
		end)

		it("ensures data integrity after each migration step", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.version = 1
			local testData = {
				initial = "value",
			}

			local migrations = {}
			migrations[2] = function(data)
				data.foo = "bar"
				return data
			end
			migrations[3] = function(data)
				data.baz = { 1, 2, 3 }
				return data
			end
			storeContext.migrations = migrations
			storeContext.latestVersion = 3

			local data = keyEntry:migrateData(testData):expect()

			expect(data).toEqual({
				initial = "value",
				foo = "bar",
				baz = { 1, 2, 3 },
			})
			expect(testData).toEqual({
				initial = "value",
			})
		end)

		it("ensures migrations start at version 2", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.version = 1
			local testData = {
				initial = "value",
			}

			local migrations = {}
			local invalidMigration = jest.fn(function(...)
				return ...
			end)
			migrations[1] = invalidMigration
			migrations[2] = function(data)
				data.foo = "bar"
				return data
			end
			storeContext.migrations = migrations
			storeContext.latestVersion = 2

			keyEntry:migrateData(testData):expect()

			expect(invalidMigration).never.toHaveBeenCalled()
		end)
	end)

	describe("KeyEntry:lock", function()
		it("correctly acquires lock for the key", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			mockDataStoreInterface._store[Constants.RECORD_SCOPE] = {
				["testKey"] = {
					value = {
						lock = {},
					},
					keyInfo = createMockDataStoreKeyInfo(),
				},
			}
			local record = keyEntry:lock():expect()
			expect(record).toEqual({})
		end)

		it("verifies and handles lock expiry", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			local oldTime = DateTime.now().UnixTimestamp - (Constants.LOCK_DURATION_SECONDS * 2)
			mockDataStoreInterface._store[Constants.RECORD_SCOPE] = {
				["testKey"] = {
					value = {
						lock = {
							id = "someOtherLock",
							expiry = oldTime,
						},
					},
					keyInfo = createMockDataStoreKeyInfo(),
				},
			}
			local record = keyEntry:lock():expect()

			expect(record).toEqual({})
		end)

		it("correctly reads and migrates data if necessary", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
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
			mockDataStoreInterface._store[Constants.RECORD_SCOPE] = {
				["testKey"] = {
					value = {
						version = 1,
						lock = {},
						file = { data = { committedData = data } } :: Types.File,
					},
					keyInfo = createMockDataStoreKeyInfo(),
				},
			}

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
		-- TODO: Add tests for concurrent lock attempts and data consistency
	end)

	describe("KeyEntry:unlock", function()
		it("correctly releases lock for the key", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})

			keyEntry:lock():expect()

			local data = {
				test = "data",
			}
			keyEntry.data = data

			keyEntry:unlock():expect()

			local record = mockDataStoreInterface._store[Constants.RECORD_SCOPE]["testKey"].value
			expect(record.lock).toEqual({})
			expect(record.file.data.committedData).toEqual(data)
		end)

		it("handles cases where the KeyEntry is already closed", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.closed = true
			local result = keyEntry
				:unlock()
				:catch(function(err)
					return err
				end)
				:expect()
			expect(result).toBe("KeyEntry is closed")
		end)

		-- TODO: Add tests for proper cleanup, saving of data, concurrent unlock attempts
	end)

	describe("KeyEntry:update", function()
		it("correctly applies transform function to key data", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry:lock():expect()

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

		it("propagates errors from transform function correctly", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry:lock():expect()

			local transformFunction = function(_)
				error("Transform error")
			end

			local result = keyEntry
				:update(transformFunction)
				:catch(function(err)
					return err
				end)
				:expect()

			expect(result).toMatch("Store:update transformFunction failed:")
			expect(result).toMatch("Transform error")
		end)

		it("handles cases where transform function returns nil", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.data = {
				count = 10,
			}
			local transformFunction = function(_)
				return nil
			end

			keyEntry:update(transformFunction):expect()
			expect(keyEntry.data.count).toBe(10)
		end)

		-- TODO: Add tests for schema validation, skipping update if data is unchanged, concurrent update attempts
	end)

	describe("KeyEntry:save", function()
		it("correctly saves data if there are unsaved mutations", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry:lock():expect()
			keyEntry:mutateKey({
				foo = "bar",
			})
			keyEntry:save():expect()

			local record = mockDataStoreInterface._store[Constants.RECORD_SCOPE]["testKey"].value
			expect(record.file.data.committedData).toEqual(keyEntry.data)
			expect(#keyEntry.unsavedMutations).toBe(0)
		end)

		it("skips save if no unsaved mutations exist", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry.data = {
				foo = "bar",
			}
			mockDataStoreInterface._store[Constants.RECORD_SCOPE] = {}

			keyEntry:save():expect()

			local record = mockDataStoreInterface._store[Constants.RECORD_SCOPE]["testKey"]
			expect(record).toBe(nil)
		end)

		it("commits snapshot after successful save", function()
			local keyEntry = KeyEntry.new({
				key = "testKey",
				storeContext = storeContext,
			})
			keyEntry:lock():expect()
			keyEntry:mutateKey({
				foo = "bar",
			})
			local snapshot = keyEntry:getSnapshot()

			keyEntry:save():expect()
			expect(keyEntry:isSnapshotCommitted(snapshot)).toBe(true)
		end)

		-- TODO: Add tests for error handling during save and data consistency
	end)

	-- TODO: Add Additional Redundancy Tests as described in the test overview
end)
