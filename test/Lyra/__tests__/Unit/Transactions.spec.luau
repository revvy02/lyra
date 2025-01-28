local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Transactions = require(ReplicatedStorage.Packages.Lyra.Transactions)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("Transactions", function()
	local mockData
	local store

	beforeEach(function()
		jest.useFakeTimers()
		mockData = MockDataStoreService.new()
		store = mockData:GetDataStore(`TX_TEST/{string.sub(HttpService:GenerateGUID(false), 1, 8)}}`)
	end)

	afterEach(function()
		jest.clearAllTimers()
	end)

	describe("readTx", function()
		it("returns committed data if no transaction ID is provided", function()
			local params = {
				store = store,
				txInfo = {
					txId = nil,
					committedData = { foo = "bar" },
				},
			}

			local p = Transactions.readTx(params)
			jest.runAllTimers()

			return expect(p).resolves.toEqual(params.txInfo.committedData)
		end)

		it("ensures correct data is returned for committed and non-committed transactions", function()
			local txInfo1 = {
				txId = "tx123",
				committedData = { foo = "bar" },
				txPatch = { { op = "replace", path = "/foo", value = "baz" } },
			}
			local tx1Data = { foo = "baz" }

			local txInfo2 = {
				txId = "tx456",
				committedData = { hello = "world" },
				txPatch = { { op = "replace", path = "/hello", value = "friend" } },
			}

			task.spawn(function()
				store:SetAsync("tx456", false)
			end)
			jest.runAllTimers()

			local p1 = Transactions.readTx({ store = store, txInfo = txInfo1 })
			local p2 = Transactions.readTx({ store = store, txInfo = txInfo2 })
			jest.runAllTimers()

			return expect(p1).resolves.toEqual(tx1Data):andThen(function()
				return expect(p2).resolves.toEqual(txInfo2.committedData)
			end)
		end)

		it("handles datastore errors gracefully", function()
			local errorMessage = "a graceful error"
			local params = {
				store = store,
				txInfo = {
					txId = "tx789",
					committedData = { foo = "bar" },
					txPatch = { { op = "replace", path = "/foo", value = "baz" } },
				},
			}

			MockDataStoreService.queueError(mockData, "GetAsync", errorMessage)

			local promise = Transactions.readTx(params)
			jest.runAllTimers()
			return expect(promise).rejects.toBe(errorMessage)
		end)

		it("handles invalid transaction data", function()
			local params = {
				store = store,
				txInfo = {
					txId = "tx789",
					committedData = { foo = "bar" },
					txPatch = { { op = "replace", path = "/foo", value = "baz" } },
				},
			}

			local getMock = MockDataStoreService.mockStoreMethod(mockData, "GetAsync", jest)
			getMock.mockImplementationOnce(function()
				return { invalid = "data" }
			end)

			return Transactions.readTx(params):andThen(function(data)
				expect(data).toEqual(params.txInfo.committedData)
			end)
		end)
	end)
end)
