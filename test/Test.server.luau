local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Util = require(ReplicatedStorage.Packages.Lyra.Util)
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
local playerPool = {}
local serverHopPlayers = {}
for _ = 1, 1000 do
	table.insert(playerPool, string.sub(game.HttpService:GenerateGUID(false), 1, 8))
end

local function spawnServer(isClosed)
	local store = require(game.ReplicatedStorage.Packages.Lyra.Store).createStore({
		name = `int-test-{string.sub(game.HttpService:GenerateGUID(false), 1, 8)}`,
		template = {},
		schema = function()
			return true
		end,
		useMock = false,
		onLockLost = function(key)
			warn("Lock lost", key)
		end,
	})

	local players = {}

	local function addPlayer()
		if #players >= 15 then
			return
		end

		local id
		local isServerHopId = false
		if #serverHopPlayers > 0 then
			id = table.remove(serverHopPlayers, 1)
			print(`Rejoining player {id}`)
			isServerHopId = true
		else
			if #playerPool == 0 then
				return
			end
			id = playerPool[math.random(1, #playerPool)]
		end

		if players[tostring(id)] then
			return
		end
		local idx = table.find(playerPool, id)
		if idx then
			table.remove(playerPool, idx)
		elseif not isServerHopId then
			warn("not in pool")
			return
		end
		table.insert(players, tostring(id))
		task.spawn(function()
			store
				:load(id)
				:catch(function(e)
					warn(e)
				end)
				:andThen(function()
					store:get(id):expect()
				end)
				:expect()
		end)
		print("Added player:", id)
	end

	local function removePlayer(id, isServerHop)
		for i, v in pairs(players) do
			if v == id then
				table.remove(players, i)
				if not isServerHop then
					table.insert(playerPool, id)
				else
					table.insert(serverHopPlayers, id)
				end
				task.spawn(function()
					store:unload(tostring(id)):expect()
				end)
				print("Removed player:", id)
				return
			end
		end
	end

	while true do
		local action = math.random(1, 100)

		if action < 10 then -- add player
			local numToAdd = 1
			if math.random() < 0.1 then
				numToAdd = math.random(1, 3)
			end
			for _ = 1, numToAdd do
				task.delay(math.random(), function()
					addPlayer()
				end)
			end
		elseif action == 100 then -- remove player
			if math.random() > 0.1 then
				continue
			end
			local numToRemove = 1
			if math.random() < 0.1 then
				numToRemove = math.random(1, 3)
			end
			for _ = 1, numToRemove do
				task.delay(math.random(), function()
					if #players == 0 then
						return
					end
					local index = math.random(1, #players)
					local id = players[index]
					removePlayer(id)
				end)
			end
		elseif action == 50 then
			if #players > 4 then
				for _ = 1, math.random(1, #players // 4) do
					task.delay(math.random(), function()
						if #players == 0 then
							return
						end
						local index = math.random(1, #players)
						local id = players[index]
						task.spawn(function()
							-- print(store._keyEntries[id], store._unloadPromises[id], store._loadPromises[id])
							store:get(id):expect()
						end)
					end)
				end
			end
		end

		if math.random() < 0.001 and #players > 0 and #serverHopPlayers < 3 then
			local p = math.random(1, #players)
			local id = players[p]
			print("Doing player rejoin", id)
			removePlayer(id, true)
		end

		if math.random() < 0.01 then
			local count = 0
			for _ in Util.activeLocks do
				count += 1
			end
			print("Active locks:", count, #players)
		end

		task.wait(0.05)

		if isClosed() then
			task.wait(1)
			for _, id in pairs(players) do
				removePlayer(id)
			end
			store:close():expect()
			return
		end
	end
end

task.spawn(function()
	local maxServers = 25
	local servers = {}
	local seed = 5
	while true do
		if math.random() < 0.05 then
			if #servers > 0 then
				local index = math.random(1, #servers)
				local close = servers[index]
				close()
				table.remove(servers, index)
			end
		end
		if math.random() < 0.1 or seed > 0 then
			if #servers < maxServers then
				seed -= 1
				local closed = false
				task.spawn(spawnServer, function()
					return closed
				end)

				table.insert(servers, function()
					closed = true
				end)
			end
		end

		print(`Servers: {#servers}/{maxServers}`)

		task.wait(1)
	end
end)
-- task.spawn(test)
-- task.spawn(test)
