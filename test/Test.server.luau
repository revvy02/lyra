local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Util = require(ReplicatedStorage.Packages.Lyra.Util)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
-- local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- _G.NOCOLOR = true
-- local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI

-- local processServiceExists, ProcessService = pcall(function()
-- 	return game:GetService("ProcessService")
-- end)

-- local status, result = runCLI(ReplicatedStorage.Packages.Lyra, {
-- 	verbose = true,
-- 	ci = false,
-- }, { ReplicatedStorage.Packages.Lyra }):awaitStatus()

-- if status == "Rejected" then
-- 	print(result)
-- end

-- if status == "Resolved" and result.results.numFailedTestSuites == 0 and result.results.numFailedTests == 0 then
-- 	if processServiceExists then
-- 		ProcessService:ExitAsync(0)
-- 	end
-- end

-- if processServiceExists then
-- 	ProcessService:ExitAsync(1)
-- end

-- return nil

require(game.ReplicatedStorage.Packages.Lyra.Log).setLevel("trace")

local Server = {}
Server.__index = Server

function Server.new(storeConfig, simulationConfig)
	local self = setmetatable({}, Server)

	self.store = require(game.ReplicatedStorage.Packages.Lyra.Store).createStore(storeConfig)
	self.players = {}
	self.isClosed = false
	self.maxPlayers = simulationConfig.maxPlayers or 15
	self.simulationConfig = simulationConfig

	task.spawn(function()
		self:runSimulation()
	end)

	return self
end

function Server:join(id)
	if #self.players >= self.maxPlayers or self.isClosed then
		return
	end

	if table.find(self.players, id) then
		return
	end
	local poolIdx = table.find(self.simulationConfig.playerPool, id)
	local hopIdx = table.find(self.simulationConfig.serverHopPlayers, id)
	if not poolIdx and not hopIdx then
		return
	end
	if poolIdx then
		table.remove(self.simulationConfig.playerPool, poolIdx)
	elseif hopIdx then
		table.remove(self.simulationConfig.serverHopPlayers, hopIdx)
	end

	table.insert(self.players, id)
	print("Adding player:", id)

	local p = self.store:load(id):catch(warn)
	self:validate(id)
	p:finally(function()
		print("Added player:", id)
	end)
	return p
end

function Server:leave(id, isServerHop)
	local idx = table.find(self.players, id)
	if not idx then
		return Promise.resolve()
	end

	print("Removing player:", id)
	table.remove(self.players, idx)

	if isServerHop and not table.find(self.simulationConfig.serverHopPlayers, id) then
		table.insert(self.simulationConfig.serverHopPlayers, id)
	else
		table.insert(self.simulationConfig.playerPool, id)
	end

	local p = self.store:unload(id):catch(warn)
	p:finally(function()
		print("Removed player:", id)
	end)
	return p
end

function Server:randomPlayer()
	if #self.players == 0 then
		return nil
	end
	return self.players[math.random(1, #self.players)]
end

local function randomString(len, rand)
	local str = ""
	for _ = 1, len do
		str = str .. string.char(rand:NextInteger(32, 126))
	end
	return str
end

local monoCounter = 0
function Server:updateRandomData()
	local id = self:randomPlayer()
	if not id then
		return
	end

	monoCounter += 1
	local myCount = monoCounter

	local function update(data)
		local r = Random.new(myCount)
		local n = r:NextNumber()
		if n < 0.01 then
			local itemId = randomString(16, r)
			local item = {
				kind = randomString(5, r),
				value = r:NextInteger(1, 100),
			}
			data.items[itemId] = item
		elseif n < 0.5 then
			data.counter = (data.counter or 0) + 1
		else
			data.str = randomString(10, r)
		end
	end

	self.store
		:update(id, function(data)
			update(data)
			return true
		end)
		:andThen(function()
			local data = self.simulationConfig.playerData[id]
			update(data)
			print(`Updated key({id}) data: {HttpService:JSONEncode(data)}`)
		end)
		:catch(warn)
end

local function getDiff(new: any, old: any): ({ [string]: any } | string)?
	local function formatValue(value)
		return type(value) == "string" and `'{value}'` or type(value) == "table" and "<table>" or tostring(value)
	end

	if type(new) ~= "table" or type(old) ~= "table" then
		return new ~= old and `new: {formatValue(new)}, old: {formatValue(old)}` or nil
	end

	local differences = {}

	for key, newValue in new do
		local oldValue = old[key]
		if type(newValue) == "table" and type(oldValue) == "table" then
			local nestedDiff = getDiff(newValue, oldValue)
			if nestedDiff then
				differences[key] = nestedDiff
			end
		elseif newValue ~= oldValue then
			differences[key] = `new: {formatValue(newValue)}, old: {formatValue(oldValue)}`
		end
	end

	for key, oldValue in old do
		if new[key] == nil then
			differences[key] = `new: nil, old: {formatValue(oldValue)}`
		end
	end

	return next(differences) and differences or nil
end

function Server:validate(id)
	return self.store
		:get(id)
		:andThen(function(data)
			local playerData = self.simulationConfig.playerData[id]
			if not Sift.Dictionary.equalsDeep(playerData, data) then
				local diff = getDiff(data, playerData)
				warn(`Data mismatch for player {id}: {HttpService:JSONEncode(diff)}`)
			else
				print(`Data validated for player {id}`)
			end
		end)
		:catch(warn)
end

function Server:close()
	self.isClosed = true
	task.wait(1) -- Give time for ongoing operations to finish
	for _, id in self.players do
		self:leave(id)
	end
	self.store:close():expect()
end

function Server:runSimulation()
	while not self.isClosed do
		if self.simulationConfig.simulationStep then
			self.simulationConfig.simulationStep(self)
		end
		task.wait(self.simulationConfig.stepDelay or 0.05)
	end
end

local Universe = {}
Universe.__index = Universe

function Universe.new(config)
	config = config or {}
	config.maxPlayers = config.maxPlayers or 1000

	local self = setmetatable({}, Universe)
	self.servers = {}
	self.playerPool = {}
	self.playerData = {}
	self.serverHopPlayers = {}
	self.config = config
	self.storeName = `int-test-{string.sub(game.HttpService:GenerateGUID(false), 1, 8)}`

	local storeConfig = {
		name = self.storeName,
		template = {
			counter = 0,
			items = {},
			str = "",
		},
		schema = function()
			return true
		end,
		useMock = false,
		onLockLost = function(key)
			warn("Lock lost", key)
		end,
	}
	self.storeConfig = storeConfig

	for _ = 1, config.maxPlayers do
		local id = string.sub(game.HttpService:GenerateGUID(false), 1, 8)
		table.insert(self.playerPool, id)
		self.playerData[id] = Sift.Dictionary.copyDeep(storeConfig.template)
	end
	return self
end

function Universe:createServer(simulationConfig)
	local config = simulationConfig or {}
	config.playerPool = self.playerPool
	config.serverHopPlayers = self.serverHopPlayers
	config.playerData = self.playerData

	local server = Server.new(self.storeConfig, config)
	table.insert(self.servers, server)
	return server
end

function Universe:closeRandomServer()
	if #self.servers > 0 then
		local index = math.random(1, #self.servers)
		self.servers[index]:close()
		table.remove(self.servers, index)
	end
end

function Universe:randomPlayer()
	if #self.playerPool == 0 then
		return nil
	end
	return self.playerPool[math.random(1, #self.playerPool)]
end

local function getActiveLocks()
	local count = 0
	for _, list in Util.activeLocks do
		if next(list) ~= nil then
			count += 1
		end
	end
	return count
end

if true then
	local doTrades = true

	local universe = Universe.new({
		maxPlayers = 150,
	})

	local serverSimulationConfig = {
		maxPlayers = 15,
		stepDelay = 0.1,
		simulationStep = function(server)
			local action = math.random(1, 100)

			local function getPlayerWithItems(exceptId)
				local start = math.random(1, #server.players)
				for i = 1, #server.players do
					local idx = (start + i) % #server.players + 1
					local id = server.players[idx]
					if id == exceptId then
						continue
					end
					local data = server.simulationConfig.playerData[id]
					if next(data.items) ~= nil then
						return id
					end
				end
				return nil
			end

			local function trade()
				print("Trying trade")
				local id1 = getPlayerWithItems()
				if not id1 then
					print("trade - No players with items")
					return
				end
				local id2 = getPlayerWithItems(id1)
				if not id2 then
					print("trade - No other players with items")
					return
				end
				-- stage data for transaction
				local data1 = server.simulationConfig.playerData[id1]
				local data2 = server.simulationConfig.playerData[id2]
				local id1ItemsToGive = {}
				local id2ItemsToGive = {}

				local function insertRandomUniqueItems(items, list)
					local itemKeys = {}
					for key in items do
						table.insert(itemKeys, key)
					end

					local numToInsert = math.random(1, #itemKeys)
					for _ = 1, numToInsert do
						local randomIndex = math.random(1, #itemKeys)
						local randomKey = table.remove(itemKeys, randomIndex)

						if not table.find(list, randomKey) then
							table.insert(list, randomKey)
						end
					end
				end

				local n = math.random()
				if n < 0.3 then
					-- one sided trade
					insertRandomUniqueItems(data1.items, id1ItemsToGive)
				elseif n < 0.6 then
					-- one sided trade
					insertRandomUniqueItems(data2.items, id2ItemsToGive)
				else
					-- two sided trade
					insertRandomUniqueItems(data2.items, id2ItemsToGive)
					insertRandomUniqueItems(data1.items, id1ItemsToGive)
				end

				local function update(state)
					local d1 = state[id1]
					local d2 = state[id2]

					for _, id in id1ItemsToGive do
						if not d1.items[id] then
							error(`tx - item({id}) not found in player({id1}) inventory`)
						end
						if d2.items[id] then
							error(`tx - item({id}) already in player({id2}) inventory`)
						end
						local item = d1.items[id]
						d1.items[id] = nil
						d2.items[id] = item
					end

					for _, id in id2ItemsToGive do
						if not d2.items[id] then
							error(`tx - item({id}) not found in player({id2}) inventory`)
						end
						if d1.items[id] then
							error(`tx - item({id}) already in player({id1}) inventory`)
						end
						local item = d2.items[id]
						d2.items[id] = nil
						d1.items[id] = item
					end

					return true
				end

				print(`Initiating trade between {id1} and {id2}`)
				print(
					`p1({id1}) inventory: {HttpService:JSONEncode(data1.items)}, giving: {HttpService:JSONEncode(
						id1ItemsToGive
					)}`
				)
				print(
					`p2({id2}) inventory: {HttpService:JSONEncode(data2.items)}, giving: {HttpService:JSONEncode(
						id2ItemsToGive
					)}`
				)
				server.store
					:tx({ id1, id2 }, update)
					:andThen(function()
						print(`Trade between {id1} and {id2} completed, doing local replication`)
						local result = update({ [id1] = data1, [id2] = data2 })
						if not result then
							error("tx - local replication failed")
						end
					end)
					:catch(warn)
			end

			if action < 10 then -- add player
				local numToAdd = 1
				if math.random() < 0.1 then
					numToAdd = math.random(1, 3)
				end
				for _ = 1, numToAdd do
					task.delay(math.random(), function()
						server:join(universe:randomPlayer())
					end)
				end
			elseif action > 97 then -- remove player
				local numToRemove = 1
				-- if math.random() < 0.1 then
				-- 	numToRemove = math.random(1, 3)
				-- end
				for _ = 1, numToRemove do
					task.delay(math.random(), function()
						if #server.players == 0 then
							return
						end
						local id = server:randomPlayer()
						server:leave(id)
					end)
				end
			elseif action > 30 and action < 80 then
				if #server.players == 0 then
					return
				end
				task.spawn(function()
					if math.random() < 0.1 then
						local id = server:randomPlayer()
						print("Validating player", id)
						server:validate(id)
					elseif math.random() < 0.11 then
						local id = server:randomPlayer()
						server.store:save(id):catch(warn)
					elseif math.random() < 0.95 then
						server:updateRandomData()
					else
						if doTrades then
							trade()
						end
					end
				end)
			end

			if math.random() < 0.01 and #server.players > 0 and #universe.serverHopPlayers < 10 then
				local id = server:randomPlayer()
				print("Doing player rejoin", id)
				server:leave(id, true)
			end

			if math.random() < 0.01 then
				print("Active locks:", getActiveLocks(), universe.config.maxPlayers - #universe.playerPool)
			end
		end,
	}

	local maxServers = 10
	local seed = 5
	while true do
		if math.random() < 0.01 then
			universe:closeRandomServer()
		end
		if math.random() < 0.15 or seed > 0 then
			if #universe.servers < maxServers then
				seed -= 1
				universe:createServer(serverSimulationConfig)
			end
		end

		print(`Servers: {#universe.servers}/{maxServers}`)

		task.wait(1)
	end
end

-- change set not being diffed correctly bug
if false then
	local universe = Universe.new({
		maxPlayers = 1,
	})

	local config = {
		maxPlayers = 1,
		stepDelay = 0.1,
	}

	local server = universe:createServer(config)
	local id = universe:randomPlayer()

	print("!!! JOIN !!!")
	server:join(id)
	print("!!! GET !!!")
	local p = server.store:get(id)
	p:await()
	print("!!! GET DONE !!!")
	task.delay(0.02, function()
		print("!!! UPDATE !!!")
		server:updateRandomData()
	end)
	print("!!! SAVE !!!")
	server.store:save(id):andThen(function()
		print("!!! SAVE DONE !!!")
	end)
	task.wait(0.1)
	print("!!! LEAVE !!!")
	server:leave(id)
	task.wait(0.1)
	print("!!! JOIN AGAIN !!!")
	server:join(id)
end

if false then
	local function runServerSimulation(server, playerId)
		while true do
			local j = server:join(playerId)
			j:catch(warn)
			task.wait(math.random())
			if math.random() < 0.05 then
				local status = j:awaitStatus()
				warn(`Server {server.store.name}, join, status: {status}, active locks: {getActiveLocks()}`)
			end
			local l = server:leave(playerId)
			l:catch(warn)
			task.wait(math.random())
			if math.random() < 0.05 then
				local status = l:awaitStatus()
				warn(`Server {server.store.name}, leave, status: {status}, active locks: {getActiveLocks()}`)
			end

			if math.random() < 0.05 then
				task.wait(2)
				warn(`Server {server.store.name}, active locks: {getActiveLocks()}`)
			end
		end
	end

	local universe = Universe.new()

	-- Spawn multiple servers, each with a unique player
	for _ = 1, 5 do -- Adjust the number of servers as needed
		local server = universe:createServer()
		local playerId = universe:randomPlayer()
		task.spawn(runServerSimulation, server, playerId)
	end
end

-- trading with race conditions test
if false then
	local universe = Universe.new({
		maxPlayers = 2, -- Only 2 players for this test
	})

	local serverSimulationConfig = {
		maxPlayers = 2, -- Only 2 players for this test
		stepDelay = 0.01, -- Reduced delay for faster execution
	}

	local server = universe:createServer(serverSimulationConfig)

	local id1 = universe.playerPool[1]
	local id2 = universe.playerPool[2]

	local function addItemUpdate(data, itemId, kind)
		data.items[itemId] = { kind = kind }
	end

	local function givePlayerItem(id, itemId, kind)
		return server.store
			:update(id, function(data)
				addItemUpdate(data, itemId, kind)
				return true
			end)
			:andThen(function()
				addItemUpdate(server.simulationConfig.playerData[id], itemId, kind)
			end)
			:catch(warn)
	end

	server:join(id1)
	server:join(id2)

	givePlayerItem(id1, "item1", "yay"):await()
	givePlayerItem(id2, "item2", "aww"):await()

	server.store:get(id1):andThen(print):await()

	-- Perform a trade
	local function update(state)
		local d1 = state[id1]
		local d2 = state[id2]
		d1.items["item2"] = d2.items["item2"]
		d2.items["item2"] = nil
		d2.items["item1"] = d1.items["item1"]
		d1.items["item1"] = nil

		return true
	end

	local p = server.store
		:tx({ id1, id2 }, update)
		:andThen(function()
			update({ [id1] = server.simulationConfig.playerData[id1], [id2] = server.simulationConfig.playerData[id2] })
		end)
		:catch(warn)

	print("UPDATE BEGIN")
	task.wait(0.581)
	server:updateRandomData()
	server:leave(id1)
	server:leave(id2)
	p:await()

	task.wait(2)
	server:join(id1)
	server:join(id2)
end
