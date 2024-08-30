local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Util = require(ReplicatedStorage.Packages.Lyra.Util)
local Promise = require(ReplicatedStorage.Packages.Promise)
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

	if self.players[tostring(id)] then
		return
	end

	table.insert(self.players, tostring(id))
	print("Added player:", id)

	return self.store
		:load(id)
		:andThen(function()
			return self.store:get(id)
		end)
		:catch(function(e)
			warn(e)
		end)
end

function Server:leave(id, isServerHop)
	local idx = table.find(self.players, id)
	if not idx then
		return Promise.resolve()
	end

	table.remove(self.players, idx)
	if not isServerHop and self.simulationConfig.playerPool then
		table.insert(self.simulationConfig.playerPool, id)
	elseif isServerHop and self.simulationConfig.serverHopPlayers then
		table.insert(self.simulationConfig.serverHopPlayers, id)
	end
	print("Removed player:", id)
	return self.store:unload(tostring(id)):catch(warn)
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

function Universe.new()
	local self = setmetatable({}, Universe)
	self.servers = {}
	self.playerPool = {}
	self.serverHopPlayers = {}
	for _ = 1, 1000 do
		table.insert(self.playerPool, string.sub(game.HttpService:GenerateGUID(false), 1, 8))
	end
	return self
end

function Universe:createServer(simulationConfig)
	local storeConfig = {
		name = `int-test-{string.sub(game.HttpService:GenerateGUID(false), 1, 8)}`,
		template = {},
		schema = function()
			return true
		end,
		useMock = false,
		onLockLost = function(key)
			warn("Lock lost", key)
		end,
	}

	local config = simulationConfig or {}
	config.playerPool = self.playerPool
	config.serverHopPlayers = self.serverHopPlayers

	local server = Server.new(storeConfig, config)
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

-- Example Usage
local universe = Universe.new()

local serverSimulationConfig = {
	maxPlayers = 20,
	stepDelay = 0.1,
	simulationStep = function(server)
		local action = math.random(1, 100)

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
		elseif action == 100 then -- remove player
			if math.random() > 0.1 then
				return
			end
			local numToRemove = 1
			if math.random() < 0.1 then
				numToRemove = math.random(1, 3)
			end
			for _ = 1, numToRemove do
				task.delay(math.random(), function()
					if #server.players == 0 then
						return
					end
					local index = math.random(1, #server.players)
					local id = server.players[index]
					server:leave(id)
				end)
			end
		elseif action == 50 then
			if #server.players > 4 then
				for _ = 1, math.random(1, #server.players // 4) do
					task.delay(math.random(), function()
						if #server.players == 0 then
							return
						end
						local index = math.random(1, #server.players)
						local id = server.players[index]
						task.spawn(function()
							server.store:get(id):expect()
						end)
					end)
				end
			end
		end

		if math.random() < 0.01 and #server.players > 0 and #universe.serverHopPlayers < 10 then
			local p = math.random(1, #server.players)
			local id = server.players[p]
			print("Doing player rejoin", id)
			server:leave(id, true)
		end

		if math.random() < 0.01 then
			local count = 0
			for _, list in Util.activeLocks do
				if next(list) ~= nil then
					count += 1
				end
			end
			print("Active locks:", count, 1000 - #universe.playerPool, #server.players, #universe.serverHopPlayers)
		end
	end,
}

-- task.spawn(function()
-- 	local maxServers = 10
-- 	local seed = 5
-- 	while true do
-- 		if math.random() < 0.05 then
-- 			universe:closeRandomServer()
-- 		end
-- 		if math.random() < 0.15 or seed > 0 then
-- 			if #universe.servers < maxServers then
-- 				seed -= 1
-- 				universe:createServer(serverSimulationConfig)
-- 			end
-- 		end

-- 		print(`Servers: {#universe.servers}/{maxServers}`)

-- 		task.wait(1)
-- 	end
-- end)

local function getActiveLocks()
	local count = 0
	for _, list in Util.activeLocks do
		if next(list) ~= nil then
			count += 1
		end
	end
	return count
end

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

local universe2 = Universe.new()

-- Spawn multiple servers, each with a unique player
for _ = 1, 5 do -- Adjust the number of servers as needed
	local server = universe2:createServer()
	local playerId = universe2:randomPlayer()
	task.spawn(runServerSimulation, server, playerId)
end
