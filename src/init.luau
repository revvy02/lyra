--!strict
--[[
	@module Lyra

	The main entry point and public facade for the Lyra library.

	This module re-exports the primary functions and constructors needed to interact
	with Lyra, simplifying the public API and hiding internal module structure.
	Users of the library should typically only need to require this top-level module.
]]

local Log = require(script.Log)
local Migrations = require(script.Migrations)
local PlayerStore = require(script.PlayerStore)

-- The public interface of the Lyra library.
return {
	--[[
		Provides helper functions for creating common migration steps.
		@interface MigrationStep (Exported Helpers)
		@field addFields (name: string, fields: { [string]: any }) -> Types.MigrationStep Creates a step to add new fields with default values.
		@field transform (name: string, transformFunc: (currentValue: { [string]: any }) -> { [string]: any }) -> Types.MigrationStep Creates a step with a custom data transformation function.
	]]
	MigrationStep = {
		addFields = Migrations.makeAddFieldsStep,
		transform = Migrations.makeTransformStep,
	},
	--[[
		Factory function to create a new PlayerStore instance.
		@function createPlayerStore
		@param context PlayerStoreContext The configuration and context for the PlayerStore.
		@return PlayerStore A new PlayerStore instance.
	]]
	createPlayerStore = PlayerStore.createPlayerStore,
	--[[
		Sets the global minimum log level for all Lyra loggers.
		@function setLogLevel
		@param level Types.LogLevel The minimum log level ("fatal", "error", "warn", "info", "debug", "trace").
	]]
	setLogLevel = Log.setLevel,
}
