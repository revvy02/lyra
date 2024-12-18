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
	},
}

describe("Random rejoin behavior", function()
	beforeEach(function()
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	it("handles rapid player rejoins across multiple servers", function()
		local mockData = MockDataStoreService.new()
		local mockMemory = MockMemoryStoreService.new()
		local universe
		local joinCount = 0
		local leaveCount = 0

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			local store = createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				schema = function(data)
					return type(data.counter) == "number", "Invalid data format"
				end,
			})
			store._store._ctx.dataStoreInterface._dataStoreService = mockData
			store._store._ctx.hashMapInterface._memoryStoreService = mockMemory

			Players.PlayerAdded:Connect(function(player)
				local success = store:load(player):await()
				if success then
					joinCount += 1
					universe:_traceEvent("PlayerJoined", { UserId = player.UserId, JoinCount = joinCount })

					store
						:update(player, function(data)
							data.counter += 1
							return true
						end)
						:await()
				end
			end)

			Players.PlayerRemoving:Connect(function(player)
				store:unload(player):await()
				leaveCount += 1
				universe:_traceEvent("PlayerLeft", { UserId = player.UserId, LeaveCount = leaveCount })
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

		-- Start multiple servers
		local servers = {}
		for _ = 1, 5 do
			local jobId = universe:StartServer(1)
			table.insert(servers, jobId)
		end

		-- Simulate random joins/leaves across servers
		for _ = 1, 50 do -- 50 iterations of random activity
			local userId = universe.rng:NextInteger(1, 5) -- 5 test players
			local serverId = servers[universe.rng:NextInteger(1, #servers)]

			if universe.rng:NextNumber() < 0.5 then
				universe:JoinPlayerToServer(userId, serverId)
			else
				universe:RemovePlayerFromServer(userId, serverId)
			end
			jest.advanceTimersByTime(universe.rng:NextInteger(50, 500))
		end

		local trace = universe:GetTrace()
		local joinEvents = 0
		local leaveEvents = 0

		for _, event in trace do
			if event.type == "PlayerJoined" then
				joinEvents += 1
			elseif event.type == "PlayerLeft" then
				leaveEvents += 1
			end
		end

		expect(joinEvents).toBeGreaterThan(0)
		expect(leaveEvents).toBeGreaterThan(0)
		expect(joinCount).toBe(joinEvents)
		expect(leaveCount).toBe(leaveEvents)
	end)
end)
