local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockHashMap = require(ReplicatedStorage.Packages.Lyra.MockHashMap)
local Universe = require(script.Parent.Parent.Universe)
local createPlayerStore = require(script.Parent.Parent.Parent.createPlayerStore)
local Tables = require(script.Parent.Parent.Parent.Tables)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

local TestConfig = {
	Template = {
		coins = 0,
		inventory = {},
	},
}

describe("PlayerStore basic functionality", function()
	beforeEach(function()
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	it("handles player join and leave correctly", function()
		local mockData = MockDataStoreService.createMockService()
		local mockMemory = MockHashMap.createMockService()
		local universe

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			local store = createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				schema = function(data)
					return type(data.coins) == "number" and type(data.inventory) == "table", "Invalid data format"
				end,
			})
			store._store._ctx.dataStoreInterface._dataStoreService = mockData
			store._store._ctx.hashMapInterface._memoryStoreService = mockMemory

			Players.PlayerAdded:Connect(function(player)
				local success = store:load(player):await()
				expect(success).toBe(true)
				universe:_traceEvent("PlayerDataLoaded", { UserId = player.UserId })

				store
					:update(player, function(data)
						data.coins += 100
						return true
					end)
					:await()
				universe:_traceEvent("CoinsAdded", { UserId = player.UserId })
			end)

			Players.PlayerRemoving:Connect(function(player)
				store:unload(player):await()
				universe:_traceEvent("PlayerDataUnloaded", { UserId = player.UserId })
			end)

			game:BindToClose(function()
				store:close():expect()
			end)
		end

		universe = Universe.new({
			seed = 1,
			places = {
				[1] = { Script = serverScript, MaxPlayers = 10 },
			},
		})

		local jobId = universe:StartServer(1)
		universe:JoinPlayerToServer(123, jobId)
		jest.advanceTimersByTime(1000)

		local trace = universe:GetTrace()
		local foundLoad = false
		local foundCoins = false
		for _, event in trace do
			if event.type == "PlayerDataLoaded" and event.details.UserId == 123 then
				foundLoad = true
			end
			if event.type == "CoinsAdded" and event.details.UserId == 123 then
				foundCoins = true
			end
		end
		expect(foundLoad).toBe(true)
		expect(foundCoins).toBe(true)

		universe:RemovePlayerFromServer(123, jobId)
		jest.advanceTimersByTime(1000)

		local foundUnload = false
		trace = universe:GetTrace()
		for _, event in trace do
			if event.type == "PlayerDataUnloaded" and event.details.UserId == 123 then
				foundUnload = true
			end
		end
		expect(foundUnload).toBe(true)

		universe:StopServer(jobId)
		jest.advanceTimersByTime(1000)

		local serverStopped = false
		trace = universe:GetTrace()
		for _, event in trace do
			if event.type == "ServerStopped" and event.details.JobId == jobId then
				serverStopped = true
			end
		end
		expect(serverStopped).toBe(true)
	end)

	it("handles server crash and data recovery", function()
		local mockData = MockDataStoreService.createMockService()
		local mockMemory = MockHashMap.createMockService()
		local universe
		local savedData

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			local store = createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				schema = function(data)
					return type(data.coins) == "number" and type(data.inventory) == "table", "Invalid data format"
				end,
			})
			store._store._ctx.dataStoreInterface._dataStoreService = mockData
			store._store._ctx.hashMapInterface._memoryStoreService = mockMemory

			Players.PlayerAdded:Connect(function(player)
				local success = store:load(player):await()
				expect(success).toBe(true)
				universe:_traceEvent("PlayerDataLoaded", { UserId = player.UserId })

				store
					:update(player, function(data)
						data.coins += 100
						return true
					end)
					:await()

				store:save(player):await()
				local ok, data = store:get(player):await()
				expect(ok).toBe(true)
				savedData = Tables.copyDeep(data)
				universe:_traceEvent("DataSaved", { UserId = player.UserId, data = data })
			end)

			Players.PlayerRemoving:Connect(function(player)
				store:unload(player):await()
			end)

			game:BindToClose(function()
				store:close():expect()
			end)
		end

		universe = Universe.new({
			seed = 1,
			places = {
				[1] = { Script = serverScript, MaxPlayers = 10 },
			},
		})

		local jobId = universe:StartServer(1)
		universe:JoinPlayerToServer(123, jobId)
		jest.advanceTimersByTime(1000)

		universe:CrashServer(jobId)
		jest.advanceTimersByTime(1000)

		local newJobId = universe:StartServer(1)
		universe:JoinPlayerToServer(123, newJobId)
		jest.advanceTimersByTime(1000)

		local trace = universe:GetTrace()
		local foundRecover = false
		for _, event in trace do
			if event.type == "DataSaved" and event.details.UserId == 123 then
				expect(Tables.equalsDeep(event.details.data, savedData)).toBe(true)
				foundRecover = true
			end
		end
		expect(foundRecover).toBe(true)
	end)
end)
