local Players = game:GetService("Players")

local Mix: any = {}

local store = Mix.createStore({
	name = "PlayerData",
	template = {},
	schema = function() end,
	migrations = Mix.migrationsFromFolder(),
})

store:update(1234, function(state)
	state.coins += 100
	return state
end)

store:tx({ 1234, 4321 }, function(state)
	state[1234].coins = state[4321].coins
	return state
end)

Players.PlayerAdded:Connect(function(player)
	store:lock(player.UserId)
end)

Players.PlayerRemoving:Connect(function(player)
	store:unlock(player.UserId)
end)
