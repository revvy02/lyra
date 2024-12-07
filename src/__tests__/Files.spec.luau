local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local DataStoreInterface = require(ReplicatedStorage.Packages.Lyra.DataStoreInterface)
local Files = require(ReplicatedStorage.Packages.Lyra.Files)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local Promise = require(ReplicatedStorage.Packages.Promise)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local beforeAll = JestGlobals.beforeAll
local jest = JestGlobals.jest

describe("Files", function()
	local mockDataStoreService
	local dataStoreInterface

	beforeAll(function()
		jest.useFakeTimers()
	end)

	beforeEach(function()
		mockDataStoreService = MockDataStoreService.createMockService()
		dataStoreInterface = DataStoreInterface.new(mockDataStoreService)
	end)

	describe("isLargeFile", function()
		it("should return true for files with a shard property", function()
			expect(Files.isLargeFile({ shard = "shardId", count = 1 })).toBe(true)
		end)

		it("should return false for files without a shard property", function()
			expect(Files.isLargeFile({ data = "testData" } :: any)).toBe(false)
		end)

		it("should return false for empty files", function()
			expect(Files.isLargeFile({} :: any)).toBe(false)
		end)
	end)

	describe("write", function()
		local maxShardSize = 1000

		it("should correctly write small files without sharding", function()
			local promise = Files.write({
				dataStoreInterface = dataStoreInterface,
				data = { test = "data" },
				maxShardSize = maxShardSize,
				key = "testKey",
				scope = "testScope",
			}):andThen(function(file)
				expect(file.data).toEqual({ test = "data" })
				expect(file.shard).toBeNil()
				expect(file.count).toBeNil()
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should correctly handle data size equal to maxShardSize", function()
			local data = string.rep("a", maxShardSize - 2)
			local promise = Files.write({
				dataStoreInterface = dataStoreInterface,
				data = data,
				maxShardSize = maxShardSize,
				key = "testKey",
				scope = "testScope",
			}):andThen(function(file)
				expect(file.data).toEqual(data)
				expect(file.shard).toBeNil()
				expect(file.count).toBeNil()
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should correctly handle empty data inputs", function()
			local promise = Files.write({
				dataStoreInterface = dataStoreInterface,
				data = {},
				maxShardSize = maxShardSize,
				key = "testKey",
				scope = "testScope",
			}):andThen(function(file)
				expect(file.data).toEqual({})
				expect(file.shard).toBeNil()
				expect(file.count).toBeNil()
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should correctly shard and write large files", function()
			local data = {
				foo = "bar",
				baz = { 1, 2, 3 },
				large = string.rep("a", maxShardSize * 2),
			}

			local promise = Files.write({
				dataStoreInterface = dataStoreInterface,
				data = data,
				maxShardSize = maxShardSize,
				key = "testKey",
				scope = "testScope",
			}):andThen(function(file)
				expect(file.shard).never.toBeNil()
				expect(file.count).toBe(3)

				local promises = {}
				for i = 1, file.count do
					table.insert(promises, dataStoreInterface:get("testScope", `{file.shard}-{i}`))
				end

				return Promise.all(promises):andThen(function(shards)
					local reconstructedData = table.concat(shards)
					reconstructedData = HttpService:JSONDecode(reconstructedData)
					expect(reconstructedData).toEqual(data)
				end)
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should handle errors during shard writing", function()
			local data = string.rep("a", 10)
			local errorMessage = "Shard write error"

			dataStoreInterface.set = function()
				return Promise.reject(errorMessage)
			end

			local promise = Files.write({
				dataStoreInterface = dataStoreInterface,
				data = data,
				maxShardSize = 6,
				key = "testKey",
				scope = "testScope",
			})
			jest.runAllTimers()
			return expect(promise).rejects.toEqual({
				error = `Failed to write file: {errorMessage}`,
				file = {
					shard = expect.any("string"),
					count = 2,
				},
			})
		end)

		it("should correctly pass userIds to datastore", function()
			local data = { test = "data" }
			local userIds = { 123, 456 }
			local setCallCount = 0

			dataStoreInterface.set = function(_, _, _, value, ids)
				setCallCount += 1
				expect(ids).toEqual(userIds)
				return Promise.resolve(value)
			end

			local promise = Files.write({
				dataStoreInterface = dataStoreInterface,
				data = data,
				maxShardSize = 10,
				key = "testKey",
				scope = "testScope",
				userIds = userIds,
			}):andThen(function()
				expect(setCallCount).toBeGreaterThan(1)
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should handle edge case with maxShardSize of 1", function()
			local data = "ab"
			local promise = Files.write({
				dataStoreInterface = dataStoreInterface,
				data = data,
				maxShardSize = 1,
				key = "testKey",
				scope = "testScope",
			}):andThen(function(file)
				expect(file.shard).never.toBeNil()
				expect(file.count).toBe(4)
			end)
			jest.runAllTimers()
			return promise
		end)
	end)

	describe("read", function()
		it("should correctly read small files without sharding", function()
			local data = { test = "data" }
			local file = { data = data }

			local promise = Files.read({
				dataStoreInterface = dataStoreInterface,
				scope = "testScope",
				file = file :: any,
			}):andThen(function(readData)
				expect(readData).toEqual(data)
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should correctly read and reassemble large files from shards", function()
			local data = { data = string.rep("a", 1100) }

			local promise = Files.write({
				dataStoreInterface = dataStoreInterface,
				data = data,
				maxShardSize = 1000,
				key = "testKey",
				scope = "testScope",
			}):andThen(function(file)
				return Files.read({
					dataStoreInterface = dataStoreInterface,
					scope = "testScope",
					file = file,
				}):andThen(function(readData)
					expect(readData).toEqual(data)
				end)
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should handle network failures during shard reading", function()
			local file = { shard = "testShard", count = 2 }
			local errorMessage = "Network error"
			local getCallCount = 0

			dataStoreInterface.get = function()
				getCallCount += 1
				if getCallCount == 1 then
					return Promise.resolve('{"part":1}')
				else
					return Promise.reject(errorMessage)
				end
			end

			local promise = Files.read({
				dataStoreInterface = dataStoreInterface,
				scope = "testScope",
				file = file,
			})
			jest.runAllTimers()
			return expect(promise).rejects.toMatch(errorMessage)
		end)

		it("should handle missing shards during read", function()
			local file = { shard = "testShard2", count = 2 }
			local getCallCount = 0

			dataStoreInterface.get = function()
				getCallCount += 1
				if getCallCount == 1 then
					return Promise.resolve('{"part')
				else
					return Promise.resolve(nil)
				end
			end

			local promise = Files.read({
				dataStoreInterface = dataStoreInterface,
				scope = "testScope",
				file = file,
			})
			jest.runAllTimers()
			return expect(promise).rejects.toMatch("Missing shard")
		end)
	end)
end)
