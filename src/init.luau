--!strict

local Log = require(script.Log)
local Migrations = require(script.Migrations)
local createPlayerStore = require(script.createPlayerStore)

return {
	MigrationStep = {
		addFields = Migrations.makeAddFieldsStep,
		transform = Migrations.makeTransformStep,
	},
	createPlayerStore = createPlayerStore,
	setLogLevel = Log.setLevel,
}
