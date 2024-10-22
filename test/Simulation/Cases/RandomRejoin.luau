local Universe = require(script.Parent.Parent.Universe)

local function run()
	local function runServerSimulation(server, playerId)
		while true do
			local j = server:join(playerId)
			j:catch(warn)
			task.wait(math.random() / 2)
			if math.random() < 0.05 then
				local status = j:awaitStatus()
				warn(`Server {server.store.name}, join, status: {status}`)
			end

			local l = server:leave(playerId)
			l:catch(warn)
			task.wait(math.random() / 2)
			if math.random() < 0.05 then
				local status = l:awaitStatus()
				warn(`Server {server.store.name}, leave, status: {status}`)
			end

			if math.random() < 0.05 then
				task.wait()
				warn(`Server {server.store.name}`)
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

return {
	run = run,
}
