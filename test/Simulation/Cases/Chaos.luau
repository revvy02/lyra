local HttpService = game:GetService("HttpService")

local Universe = require(script.Parent.Parent.Universe)

local function run()
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

return {
	run = run,
}
