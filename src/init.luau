--!strict

local createPlayerStore = require(script.createPlayerStore)
local migrationsFromFolder = require(script.migrationsFromFolder)

return {
	createPlayerStore = createPlayerStore,
	migrationsFromFolder = migrationsFromFolder,
}
