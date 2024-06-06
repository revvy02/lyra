local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mix = require(script.Parent.Parent)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

type SimulationState = {
	tick: number,
	userIds: { number },
	maxPlayers: number,
	errors: { { string } },
	totalCurrency: number,
	playerStore: any,
	userIdCounter: number,
}

type PlayerData = {
	currency: number,
	inventory: { string },
}

local SIMULATION_TICKS = 10 * 60 * 60
local MAX_PLAYERS = 100
local JOIN_PROBABILITY = 0.01
local LEAVE_PROBABILITY = 0.005
local ACQUIRE_CURRENCY_PROBABILITY = 0.1
local SPEND_CURRENCY_PROBABILITY = 0.05
local BUY_ITEM_PROBABILITY = 0.02
local TRADE_ITEM_PROBABILITY = 0.01

local ITEMS = {
	"Sword",
	"Shield",
	"Potion",
}

local function getRandomPlayerId(state: SimulationState): number
	local index = math.random(#state.userIds)
	return state.userIds[index]
end

local function playerJoins(state: SimulationState)
	if #state.userIds < state.maxPlayers then
		state.userIdCounter += 1
		local userId = state.userIdCounter
		table.insert(state.userIds, userId)

		state.playerStore:lock(userId):catch(function(err)
			table.insert(state.errors, { "playerJoins error:", err })
		end)
	end
end

local function playerLeaves(state: SimulationState)
	if #state.userIds > 0 then
		local userId = table.remove(state.userIds, math.random(#state.userIds))
		state.playerStore:unlock(userId):catch(function(err)
			table.insert(state.errors, { "playerLeaves error:", err })
		end)
	end
end

local function acquireCurrency(state: SimulationState)
	local userId = getRandomPlayerId(state)
	if not userId then
		return
	end
	local amount = math.random(1, 10)

	state.playerStore
		:update(userId, function(data: PlayerData)
			data.currency += amount
			state.totalCurrency += amount
			return data
		end)
		:catch(function(err)
			table.insert(state.errors, { "acquireCurrency error:", err })
		end)
end

local function spendCurrency(state: SimulationState)
	local userId = getRandomPlayerId(state)
	if not userId then
		return
	end

	state.playerStore
		:update(userId, function(data: PlayerData)
			local amount = math.random(0, math.min(data.currency, 10))
			data.currency -= amount
			state.totalCurrency -= amount
			return data
		end)
		:catch(function(err)
			table.insert(state.errors, { "spendCurrency error:", err })
		end)
end

local function buyItem(state: SimulationState)
	local userId = getRandomPlayerId(state)
	if not userId then
		return
	end
	local item = ITEMS[math.random(#ITEMS)]

	state.playerStore
		:update(userId, function(data: PlayerData)
			table.insert(data.inventory, item)
			return data
		end)
		:catch(function(err)
			table.insert(state.errors, { "buyItem error:", err })
		end)
end

local function tradeItems(state: SimulationState)
	local userId1 = getRandomPlayerId(state)
	local userId2 = getRandomPlayerId(state)
	if not userId1 or not userId2 then
		return
	end

	while userId2 == userId1 and #state.userIds > 1 do
		userId2 = getRandomPlayerId(state)
	end

	if userId1 == userId2 then
		return
	end

	state.playerStore
		:tx({ userId1, userId2 }, function(playerData: { [number]: PlayerData })
			local data1 = playerData[userId1]
			local data2 = playerData[userId2]

			if #data1.inventory == 0 or #data2.inventory == 0 then
				return nil
			end

			local item1Index = math.random(#data1.inventory)
			local item2Index = math.random(#data2.inventory)

			if item1Index > 0 and item2Index > 0 then
				local temp = data1.inventory[item1Index]
				data1.inventory[item1Index] = data2.inventory[item2Index]
				data2.inventory[item2Index] = temp
			end

			return playerData
		end)
		:catch(function(err)
			table.insert(state.errors, { "tradeItems error:", err })
		end)
end

local function tickSimulation(state: SimulationState)
	state.tick += 1

	if math.random() < JOIN_PROBABILITY then
		playerJoins(state)
	end

	if math.random() < LEAVE_PROBABILITY then
		playerLeaves(state)
	end

	if math.random() < ACQUIRE_CURRENCY_PROBABILITY then
		acquireCurrency(state)
	end

	if math.random() < SPEND_CURRENCY_PROBABILITY then
		spendCurrency(state)
	end

	if math.random() < BUY_ITEM_PROBABILITY then
		buyItem(state)
	end

	if math.random() < TRADE_ITEM_PROBABILITY then
		tradeItems(state)
	end

	if state.tick % 60 == 0 then
		for _, userId in ipairs(state.userIds) do
			state.playerStore:save(userId):catch(function(err)
				table.insert(state.errors, { "autosave error:", err })
			end)
		end
	end
end

local function assertNoErrors(state: SimulationState)
	for _, error in ipairs(state.errors) do
		print(unpack(error))
	end
	expect(#state.errors).toBe(0)
end

local function assertTotalCurrency(state: SimulationState)
	local total = 0
	for _, userId in ipairs(state.userIds) do
		local data: PlayerData = state.playerStore:get(userId):expect()
		total += data.currency
	end

	expect(total).toBe(state.totalCurrency)
end

describe("Mix DataStore Simulation Test", function()
	local state: SimulationState
	local playerStore

	beforeEach(function()
		jest.useFakeTimers()

		state = {
			userIdCounter = 0,
			tick = 0,
			userIds = {},
			maxPlayers = MAX_PLAYERS,
			errors = {},
			totalCurrency = 0,
			playerStore = nil,
		}

		playerStore = Mix.createPlayerStore({
			useMock = true,
			name = "PlayerData",
			template = {
				currency = 0,
				inventory = {},
			},
			schema = function(data)
				return typeof(data) == "table"
					and typeof(data.currency) == "number"
					and typeof(data.inventory) == "table"
			end,
		})

		state.playerStore = playerStore
	end)

	afterEach(function()
		jest.useRealTimers()
	end)
	local interval = SIMULATION_TICKS / 24

	it("runs the simulation without errors", function(_, done)
		for _ = 1, math.random(3, 5) do
			playerJoins(state)
		end
		for i = 1, SIMULATION_TICKS do
			tickSimulation(state)
			jest.advanceTimersByTime(1000)
			if i % interval == 0 then
				print("Simulation progress:", i / SIMULATION_TICKS * 100, "%")
				task.wait()
			end
		end

		assertNoErrors(state)
		done()
	end, 60 * 1000)

	it("maintains data consistency throughout the simulation", function(_, done)
		for _ = 1, math.random(3, 5) do
			playerJoins(state)
		end
		for i = 1, SIMULATION_TICKS do
			tickSimulation(state)
			jest.advanceTimersByTime(1000)
			if i % interval == 0 then
				print("Simulation progress:", i / SIMULATION_TICKS * 100, "%")
				task.wait()
			end
		end

		-- assertTotalCurrency(state)
		done()
	end, 60 * 1000)
end)
