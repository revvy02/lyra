local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

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

return Universe
