local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Universe = require(script.Parent.Parent.Universe)

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

describe("Game simulation example", function()
	it("demonstrates a lobby-game flow with multiple players", function()
		local lobbyScript = function(env)
			local Players = env.Players
			local TeleportService = env.TeleportService
			local GAME_PLACE_ID = 2

			local function checkStartGame()
				local players = Players:GetPlayers()
				if #players >= 2 then
					for _, userId in players do
						TeleportService:Teleport(GAME_PLACE_ID, userId)
					end
				end
			end

			Players.PlayerAdded:Connect(checkStartGame)
		end

		local gameScript = function(env)
			local Players = env.Players
			local activePlayers = {}

			local roundActive = false
			local roundStartTime = 0
			local ROUND_DURATION = 60

			Players.PlayerAdded:Connect(function(userId)
				activePlayers[userId] = true

				if not roundActive then
					roundActive = true
					roundStartTime = os.clock()
				end
			end)

			Players.PlayerRemoving:Connect(function(userId)
				activePlayers[userId] = nil
			end)

			while true do
				if roundActive then
					local elapsed = os.clock() - roundStartTime
					if elapsed >= ROUND_DURATION then
						break
					end
				end
				task.wait(1)
			end
		end

		local universe = Universe.new({
			seed = 123,
			places = {
				[1] = { Script = lobbyScript, MaxPlayers = 10 },
				[2] = { Script = gameScript, MaxPlayers = 4 },
			},
		})

		local lobbyId = universe:StartServer(1)

		universe:JoinPlayerToServer(1, lobbyId)
		jest.advanceTimersByTime(1000)

		universe:JoinPlayerToServer(2, lobbyId)
		jest.advanceTimersByTime(1000)

		local gameServers = universe:GetServersForPlace(2)
		expect(#gameServers).toBe(1)

		jest.advanceTimersByTime(60000)

		local trace = universe:GetTrace()

		local function countEvents(eventType: string): number
			local count = 0
			for _, event in trace do
				if event.type == eventType then
					count += 1
				end
			end
			return count
		end

		expect(countEvents("ServerStarted")).toBeGreaterThanOrEqual(2)
		expect(countEvents("PlayerJoined")).toBeGreaterThanOrEqual(4)
		print(trace)
	end)
end)
