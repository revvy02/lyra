--!strict

local Log = require(script.Log)
local Migrations = require(script.Migrations)
local PlayerStore = require(script.PlayerStore)

return {
	MigrationStep = {
		addFields = Migrations.makeAddFieldsStep,
		transform = Migrations.makeTransformStep,
	},
	createPlayerStore = PlayerStore.createPlayerStore,
	setLogLevel = Log.setLevel,
}
