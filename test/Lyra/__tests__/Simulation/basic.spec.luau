local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Universe = require(script.Parent.Parent.Universe)
local PlayerStore = require(ReplicatedStorage.Packages.Lyra.PlayerStore)
local Tables = require(ReplicatedStorage.Packages.Lyra.Tables)

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
		local mockData = MockDataStoreService.new()
		local mockMemory = MockMemoryStoreService.new()
		local universe

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			local store = PlayerStore.createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				dataStoreService = mockData,
				memoryStoreService = mockMemory,
				schema = function(data)
					return typeof(data.coins) == "number" and typeof(data.inventory) == "table", "Invalid data format"
				end,
			})

			Players.PlayerAdded:Connect(function(player)
				store:loadAsync(player)
				universe:_traceEvent("PlayerDataLoaded", { UserId = player.UserId })

				store:updateAsync(player, function(data)
					data.coins += 100
					return true
				end)

				universe:_traceEvent("CoinsAdded", { UserId = player.UserId })
			end)

			Players.PlayerRemoving:Connect(function(player)
				store:unloadAsync(player)
				universe:_traceEvent("PlayerDataUnloaded", { UserId = player.UserId })
			end)

			game:BindToClose(function()
				store:closeAsync()
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
		local mockData = MockDataStoreService.new()
		local mockMemory = MockMemoryStoreService.new()
		local universe
		local savedData

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			local store = PlayerStore.createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				dataStoreService = mockData,
				memoryStoreService = mockMemory,
				schema = function(data)
					return typeof(data.coins) == "number" and typeof(data.inventory) == "table", "Invalid data format"
				end,
			})

			Players.PlayerAdded:Connect(function(player)
				store:loadAsync(player)
				universe:_traceEvent("PlayerDataLoaded", { UserId = player.UserId })

				store:update(player, function(data)
					data.coins += 100
					return true
				end)

				store:saveAsync(player)
				local data = store:getAsync(player)
				savedData = Tables.copyDeep(data)
				universe:_traceEvent("DataSaved", { UserId = player.UserId, data = data })
			end)

			Players.PlayerRemoving:Connect(function(player)
				store:unloadAsync(player)
			end)

			game:BindToClose(function()
				store:closeAsync()
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

	it("player idling in server", function()
		local mockData = MockDataStoreService.new()
		local mockMemory = MockMemoryStoreService.new()
		MockMemoryStoreService.setErrorRate(mockMemory, "UpdateAsync", 0.1)
		MockMemoryStoreService.setRandomLatency(mockMemory, 0.1, 0.5)
		local universe
		local idleDurationSeconds = 60 * 60

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			local store = PlayerStore.createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				dataStoreService = mockData,
				memoryStoreService = mockMemory,
				schema = function(data)
					return typeof(data.coins) == "number" and typeof(data.inventory) == "table", "Invalid data format"
				end,
			})

			Players.PlayerAdded:Connect(function(player)
				store:loadAsync(player)
				universe:_traceEvent("PlayerDataLoaded", { UserId = player.UserId })

				store:updateAsync(player, function(data)
					data.coins += 100
					return true
				end)

				universe:_traceEvent("CoinsAdded", { UserId = player.UserId })
			end)

			Players.PlayerRemoving:Connect(function(player)
				store:unloadAsync(player)
				universe:_traceEvent("PlayerDataUnloaded", { UserId = player.UserId })
			end)

			game:BindToClose(function()
				store:closeAsync()
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
		jest.advanceTimersByTime(5000)

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

		jest.advanceTimersByTime(idleDurationSeconds * 1000)

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
end)
