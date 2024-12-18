local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
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
		counter = 0,
		items = {},
		str = "",
	},
}

describe("Change set diff regression", function()
	beforeEach(function()
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	it("handles concurrent save and update operations correctly", function()
		local mockData = MockDataStoreService.new()
		local mockMemory = MockMemoryStoreService.new()
		local universe
		local dataUpdated = false
		local dataSaved = false

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			local store = createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				schema = function(data)
					return type(data.counter) == "number" and type(data.items) == "table" and type(data.str) == "string",
						"Invalid data format"
				end,
			})
			store._store._ctx.dataStoreInterface._dataStoreService = mockData
			store._store._ctx.hashMapInterface._memoryStoreService = mockMemory

			Players.PlayerAdded:Connect(function(player)
				local success = store:load(player):await()
				expect(success).toBe(true)
				universe:_traceEvent("PlayerDataLoaded", { UserId = player.UserId })

				-- Get data
				store:get(player):await()
				universe:_traceEvent("DataGet", { UserId = player.UserId })

				-- Schedule update
				task.delay(0.02, function()
					store
						:update(player, function(data)
							data.counter += 1
							data.str = "updated"
							data.items["new_item"] = { kind = "test" }
							return true
						end)
						:await()
					dataUpdated = true
					universe:_traceEvent("DataUpdated", { UserId = player.UserId })
				end)

				-- Save immediately
				store
					:save(player)
					:tap(function()
						dataSaved = true
						universe:_traceEvent("DataSaved", { UserId = player.UserId })
					end)
					:await()
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
				[1] = { Script = serverScript, MaxPlayers = 1 },
			},
		})

		local jobId = universe:StartServer(1)
		universe:JoinPlayerToServer(1, jobId)
		jest.advanceTimersByTime(1000)

		universe:RemovePlayerFromServer(1, jobId)
		jest.advanceTimersByTime(1000)

		universe:JoinPlayerToServer(1, jobId)
		jest.advanceTimersByTime(1000)

		local trace = universe:GetTrace()
		local events = {}
		for _, event in trace do
			if event.type == "DataGet" or event.type == "DataUpdated" or event.type == "DataSaved" then
				table.insert(events, event.type)
			end
		end

		-- Verify event order
		expect(events[1]).toBe("DataGet")
		expect(events[2]).toBe("DataSaved")
		expect(events[3]).toBe("DataUpdated")

		-- Verify operations completed
		expect(dataUpdated).toBe(true)
		expect(dataSaved).toBe(true)
	end)
end)
