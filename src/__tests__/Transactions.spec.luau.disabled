local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local DataStoreInterface = require(ReplicatedStorage.Packages.Lyra.DataStoreInterface)
local Transactions = require(ReplicatedStorage.Packages.Lyra.Transactions)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local Promise = require(ReplicatedStorage.Packages.Promise)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach

describe.each({
	{
		name = "MockDataStoreService",
		dataStoreService = MockDataStoreService.createMockService(),
	},
	{
		name = "DataStoreService",
		dataStoreService = game:GetService("DataStoreService"),
	},
})("Transactions with $name", function(services)
	local dataStoreInterface
	local txScope = `TX_TEST/{string.sub(HttpService:GenerateGUID(false), 1, 8)}}`
	local params

	beforeEach(function()
		dataStoreInterface = DataStoreInterface.new(services.dataStoreService)
		params = {
			dataStoreInterface = dataStoreInterface,
			scope = txScope,
		}
	end)

	describe("readTx", function()
		it("returns committed data if no transaction ID is provided", function()
			params.txInfo = {
				txId = nil,
				committedData = { foo = "bar" },
			}

			return Transactions.readTx(params):andThen(function(data)
				expect(data).toEqual(params.txInfo.committedData)
			end)
		end)

		it("ensures correct data is returned for committed and non-committed transactions", function()
			local txInfo1 = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txData = { foo = "baz" },
			}
			local txInfo2 = {
				txId = "tx456",
				committedData = { hello = "world" },
				txData = { hello = "friend" },
			}

			return Promise.all({
				dataStoreInterface:set(params.scope, "tx456", false),
			}):andThen(function()
				local p1 = table.clone(params)
				p1.txInfo = txInfo1
				local p2 = table.clone(params)
				p2.txInfo = txInfo2
				local data1 = Transactions.readTx(p1):expect()
				local data2 = Transactions.readTx(p2):expect()

				expect(data1).toEqual(txInfo1.txData)
				expect(data2).toEqual(txInfo2.committedData)
			end)
		end)
	end)
end)
