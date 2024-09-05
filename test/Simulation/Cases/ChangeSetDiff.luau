local Universe = require(script.Parent.Parent.Universe)

local function run()
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

return {
	run = run,
}
