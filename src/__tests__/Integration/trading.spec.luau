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
		items = {},
	},
}

describe("Trading race conditions", function()
	beforeEach(function()
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	it("handles trading items between players with potential race conditions", function()
		local mockData = MockDataStoreService.new()
		local mockMemory = MockMemoryStoreService.new()
		local universe
		local tradeInitiated = false

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			local store = createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				schema = function(data)
					return type(data.items) == "table", "Invalid data format"
				end,
			})
			store._store._ctx.dataStoreInterface._dataStoreService = mockData
			store._store._ctx.hashMapInterface._memoryStoreService = mockMemory

			local function addItemToPlayer(player, itemId, kind)
				store
					:update(player, function(data)
						data.items[itemId] = { kind = kind }
						return true
					end)
					:await()
				universe:_traceEvent("ItemAdded", { UserId = player.UserId, ItemId = itemId, Kind = kind })
			end

			Players.PlayerAdded:Connect(function(player)
				local success = store:load(player):await()
				expect(success).toBe(true)
				universe:_traceEvent("PlayerDataLoaded", { UserId = player.UserId })

				if player.UserId == 1 then
					addItemToPlayer(player, "item1", "yay")
				elseif player.UserId == 2 then
					addItemToPlayer(player, "item2", "aww")
				end

				-- Simulate trade when both players are present
				if #Players:GetPlayers() == 2 and not tradeInitiated then
					tradeInitiated = true
					local players = Players:GetPlayers()
					local player1 = players[1]
					local player2 = players[2]

					-- Add random data during trade to test race conditions
					task.delay(0.581, function()
						store
							:update(player1, function(data)
								data.items["random_item"] = { kind = "random" }
								return true
							end)
							:await()
						universe:_traceEvent("RandomItemAdded", { UserId = player1.UserId })
					end)

					-- Perform trade
					local function update(state)
						local d1 = state[player1]
						local d2 = state[player2]
						d1.items["item2"] = d2.items["item2"]
						d2.items["item2"] = nil
						d2.items["item1"] = d1.items["item1"]
						d1.items["item1"] = nil
						return true
					end

					store:tx({ player1, player2 }, update):await()
					universe:_traceEvent("TradeCompleted", { Player1 = player1.UserId, Player2 = player2.UserId })
				end
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
				[1] = { Script = serverScript, MaxPlayers = 2 },
			},
		})

		local jobId = universe:StartServer(1)
		universe:JoinPlayerToServer(1, jobId)
		jest.advanceTimersByTime(1000)
		universe:JoinPlayerToServer(2, jobId)
		jest.advanceTimersByTime(1000)

		-- Players leave and rejoin to verify state persistence
		universe:RemovePlayerFromServer(1, jobId)
		universe:RemovePlayerFromServer(2, jobId)
		jest.advanceTimersByTime(1000)

		universe:JoinPlayerToServer(1, jobId)
		universe:JoinPlayerToServer(2, jobId)
		jest.advanceTimersByTime(1000)

		local trace = universe:GetTrace()
		local tradeCompleted = false
		local finalState = {
			player1Items = {},
			player2Items = {},
		}

		for _, event in trace do
			if event.type == "TradeCompleted" then
				tradeCompleted = true
			elseif event.type == "ItemAdded" then
				if event.details.UserId == 1 then
					finalState.player1Items[event.details.ItemId] = event.details.Kind
				elseif event.details.UserId == 2 then
					finalState.player2Items[event.details.ItemId] = event.details.Kind
				end
			end
		end

		expect(tradeCompleted).toBe(true)
		expect(finalState.player1Items["item2"]).toBe("aww")
		expect(finalState.player2Items["item1"]).toBe("yay")
	end)
end)
