--!strict

local Store = require(script.Store)
local migrationsFromFolder = require(script.migrationsFromFolder)

return {
	createStore = Store.createStore,
	migrationsFromFolder = migrationsFromFolder,
}
