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

describe("Files", function()
	local mockDataStoreService
	local dataStoreInterface

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
	end)

	describe("write", function()
		local maxShardSize = 1000

		it("should correctly write small files without sharding", function()
			local data = { test = "data" }

			return Files.write({
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
		end)

		it("should correctly handle data size equal to maxShardSize", function()
			local data = string.rep("a", maxShardSize - 2) -- subtract 2 for json "{}"

			return Files.write({
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
		end)

		it("should correctly handle empty data inputs", function()
			local data = {}

			return Files.write({
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
		end)

		it("should correctly shard and write large files", function()
			local data = {
				foo = "bar",
				baz = { 1, 2, 3 },
				large = string.rep("a", maxShardSize * 2),
			}

			return Files.write({
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
		end)

		it("should handle errors during shard writing", function()
			local data = string.rep("a", maxShardSize + 1)
			local errorMessage = "Shard write error"

			mockDataStoreService.set = function()
				return Promise.reject(errorMessage)
			end

			return Files.write({
				dataStoreInterface = dataStoreInterface,
				data = data,
				maxShardSize = maxShardSize,
				key = "testKey",
				scope = "testScope",
			}):catch(function(err)
				expect(err.error).toMatch(errorMessage)
				expect(err.file.shard).never.toBeNil()
				expect(err.file.count).toBe(2)
			end)
		end)
	end)

	describe("read", function()
		it("should correctly read small files without sharding", function()
			local data = { test = "data" }
			local file = { data = data }

			return Files.read({
				dataStoreInterface = dataStoreInterface,
				scope = "testScope",
				file = file :: any,
			}):andThen(function(readData)
				expect(readData).toEqual(data)
			end)
		end)

		it("should correctly read and reassemble large files from shards", function()
			local data = { data = string.rep("a", 1100) }

			return Files.write({
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
		end)
	end)
end)
