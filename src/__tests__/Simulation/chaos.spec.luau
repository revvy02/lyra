local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
end)

describe("PlayerStore chaos test", function()
	it("runs a long-term chaos test for 10 hours", function()
		local TEST_DURATION = 60 * 60 * 10
		local MAX_PLAYERS = 20
		local OPERATION_INTERVAL = 1
		local failures = {}
		local SEED = 10

		local serverRandCount = 0
		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			serverRandCount += 1
			local serverRand = Random.new(SEED + serverRandCount)

			local function onRejection(err)
				if
					err == "Load was cancelled"
					or err == "Load already in progress"
					or err == "Key not loaded"
					or err == "Store is closed"
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
					end,
					function()
						return store
							:update(player, function(data)
								data.coins = math.max(0, data.coins - serverRand:NextInteger(1, 50))
								return true
							end)
							:catch(onRejection)
					end,
					function()
						local itemId = tostring(serverRand:NextInteger(1, 100))
						return store
							:update(player, function(data)
								data.inventory[itemId] = true
								return true
							end)
							:catch(onRejection)
					end,
					function()
						return store:get(player):catch(onRejection)
					end,
					function()
						return store:save(player):catch(onRejection)
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
				store:close():catch(onRejection)
			end)

			local startTime = os.clock()
			while os.clock() - startTime < TEST_DURATION do
				local players = Players:GetPlayers()
				if #players > 0 then
					local randomPlayer = players[serverRand:NextInteger(1, #players)]
					randomOperation(randomPlayer)
				end
				task.wait(OPERATION_INTERVAL)
			end

			store:close():catch(onRejection)
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
			if rand:NextNumber() < 0.1 then
				universe:RemoveRandomPlayer(1)
			end
			if rand:NextNumber() < 0.1 then
				universe:StopRandomServer(1)
			end
			if rand:NextNumber() < 0.1 then
				universe:CrashRandomServer(1)
			end
		end

		local startTime = os.clock()
		local t = 0
		while os.clock() - startTime < TEST_DURATION and #failures == 0 do
			simulatePlayerActivity()
			jest.advanceTimersByTime(1000)
			t += 1
		end

		print(universe.seed, #failures, #universe:GetTrace())

		if #failures > 0 then
			error(failures[1].error)
		end
		expect(#failures).toBe(0)
		if #failures > 0 then
			for _, failure in failures do
				print(string.format("[%.2f] %s", failure.time, failure.error))
			end
		end
	end, 20_000)
end)
