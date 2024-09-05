local Universe = require(script.Parent.Parent.Universe)

local function run()
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

return {
	run = run,
}
