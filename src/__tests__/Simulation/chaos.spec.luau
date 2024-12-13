local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockHashMap = require(ReplicatedStorage.Packages.Lyra.MockHashMap)
local Universe = require(script.Parent.Parent.Universe)
local createPlayerStore = require(script.Parent.Parent.Parent.createPlayerStore)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

beforeEach(function()
	jest.useFakeTimers()
end)

afterEach(function()
	jest.clearAllTimers()
	jest.useRealTimers()
end)

describe("PlayerStore chaos test", function()
	local seeds = { 1, 2, 3 }
	local durations = { 60 * 60 * 2, 60 * 60 * 4, 60 * 60 * 6 }
	-- local seeds = { 1 }
	-- local durations = { 60 * 60 * 5 }
	local testData = {}
	for _, seed in seeds do
		for _, duration in durations do
			table.insert(testData, { seed = seed, duration = duration })
		end
	end

	it.each(testData)("runs a long-term chaos test with seed $seed for $duration secs", function(params)
		local TEST_DURATION = params.duration
		local SEED = params.seed
		local MAX_PLAYERS = 20
		local OPERATION_INTERVAL = 10

		local canonData = {}

		local failures = {}
		local numIterations = 0

		local serverRandCount = 0
		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			serverRandCount += 1
			local serverRand = Random.new(SEED + serverRandCount)

			local function onRejection(err)
				if
					string.find(err, "Load was cancelled")
					or string.find(err, "Load already in progress")
					or string.find(err, "Key not loaded")
					or string.find(err, "Store is closed")
					or string.find(err, "Transaction transform function returned false")
				then
					return
				end
				table.insert(failures, {
					time = os.clock(),
					error = tostring(err),
				})
			end

			local store = createPlayerStore({
				name = "PlayerData",
				template = {
					coins = 0,
					inventory = {},
				},
				schema = function(data)
					return type(data.coins) == "number" and type(data.inventory) == "table", "Invalid data format"
				end,
				logCallback = function(logMessage)
					if logMessage.level == "error" or logMessage.level == "fatal" then
						onRejection(logMessage.message)
					end
				end,
			})
			store._store._ctx.dataStoreInterface._dataStoreService = MockDataStoreService.createMockService()
			store._store._ctx.hashMapInterface._memoryStoreService = MockHashMap.createMockService()

			local function randomOperation(player)
				local operations = {
					function()
						return store
							:update(player, function(data)
								data.coins += serverRand:NextInteger(1, 100)
								return true
							end)
							:catch(onRejection)
							:await()
					end,
					function()
						return store
							:update(player, function(data)
								data.coins = math.max(0, data.coins - serverRand:NextInteger(1, 50))
								return true
							end)
							:catch(onRejection)
							:await()
					end,
					function()
						local itemId = tostring(serverRand:NextInteger(1, 100))
						return store
							:update(player, function(data)
								data.inventory[itemId] = true
								return true
							end)
							:catch(onRejection)
							:await()
					end,
					function()
						return store:get(player):catch(onRejection):await()
					end,
					function()
						return store:save(player):catch(onRejection):await()
					end,
					function()
						local players = Players:GetPlayers()
						if #players < 2 then
							return
						end
						local otherPlayers = table.clone(players)
						table.remove(otherPlayers, table.find(otherPlayers, player))
						local otherPlayer = otherPlayers[serverRand:NextInteger(1, #otherPlayers)]
						return store
							:tx({ player, otherPlayer }, function(state)
								state[player].coins, state[otherPlayer].coins =
									state[otherPlayer].coins, state[player].coins
								return true
							end)
							:catch(onRejection)
							:await()
					end,
				}

				local operation = operations[serverRand:NextInteger(1, #operations)]
				return operation()
			end

			Players.PlayerAdded:Connect(function(userId)
				store:load(userId):catch(onRejection)
			end)

			Players.PlayerRemoving:Connect(function(userId)
				store:unload(userId):catch(onRejection)
			end)

			game:BindToClose(function()
				store:close():catch(onRejection):expect()
			end)

			while true do
				local players = Players:GetPlayers()
				if #players > 0 then
					local randomPlayer = players[serverRand:NextInteger(1, #players)]
					randomOperation(randomPlayer)
				end
				task.wait(OPERATION_INTERVAL)
				numIterations += 1
			end
		end

		local universe = Universe.new({
			seed = SEED,
			places = {
				[1] = { Script = serverScript, MaxPlayers = MAX_PLAYERS },
			},
		})

		local rand = Random.new(SEED)
		local function simulatePlayerActivity()
			if rand:NextNumber() < 0.1 then
				universe:JoinRandomPlayerToPlace(1)
			end
			if rand:NextNumber() < 0.01 then
				universe:RemoveRandomPlayer()
			end
			if rand:NextNumber() < 0.005 then
				universe:StopRandomServer(1)
			end
			if rand:NextNumber() < 0.005 then
				universe:CrashRandomServer(1)
			end
		end

		local startTime = os.clock()
		local t = 0
		while os.clock() - startTime < TEST_DURATION and #failures == 0 do
			task.spawn(simulatePlayerActivity)
			jest.advanceTimersByTime(OPERATION_INTERVAL * 1000)
			t += 1
			if t % 500 == 0 then
				RunService.Heartbeat:Wait()
			end
		end

		jest.clearAllTimers()

		print(universe.seed, #failures, #universe:GetTrace())
		print("iterations: ", numIterations)

		if #failures > 0 then
			for _, failure in failures do
				print(string.format("[%.2f] %s", failure.time, failure.error))
			end
		end
		expect(#failures).toBe(0)
	end, 20_000)
end)
