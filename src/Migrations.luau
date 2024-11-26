--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Types = require(script.Parent.Types)
local Sift = require(ReplicatedStorage.Packages.Sift)

type Data = { [string]: any }

type MigrationImpl = {
	__index: MigrationImpl,
	new: () -> Migration,
	fields: (self: Migration, name: string, fields: Data) -> Migration,
	transform: (self: Migration, name: string, transformFunc: (currentValue: Data) -> Data) -> Migration,
	finalize: (self: Migration) -> { Types.MigrationStep },
}

type MigrationProps = {
	steps: { Types.MigrationStep },
}

type Migration = typeof(setmetatable({} :: MigrationProps, {} :: MigrationImpl))

local Migration: MigrationImpl = {} :: MigrationImpl
Migration.__index = Migration

function Migration.new(): Migration
	return setmetatable({ steps = {} }, Migration)
end

function Migration:fields(name: string, fields: Data): Migration
	table.insert(self.steps, {
		name = name,
		apply = function(data)
			return Sift.Dictionary.mergeDeep(fields, data)
		end,
	})
	return self
end

function Migration:transform(name: string, transformFunc: (currentValue: Data) -> Data): Migration
	table.insert(self.steps, {
		name = name,
		apply = transformFunc,
	})
	return self
end

function Migration:finalize(): { Types.MigrationStep }
	return self.steps
end

local function validateMigrationSteps(steps: { Types.MigrationStep })
	assert(typeof(steps) == "table", "steps must be a table")
	for _, step in steps do
		assert(typeof(step) == "table", "step must be a table")
		assert(typeof(step.name) == "string", "step.name must be a string")
		assert(typeof(step.apply) == "function", "step.apply must be a function")
	end
end

type ApplyMigrationStepsParams = {
	logger: Types.Logger,
	data: Data,
	steps: { Types.MigrationStep },
}

local function applyMigrationSteps(params: ApplyMigrationStepsParams): Promise.TypedPromise<Data>
	local logger = params.logger:extend({ method = "applyMigrationSteps" })

	local currentData = params.data
	for _, step in params.steps do
		logger:log("trace", "applying migration step", { stepName = step.name })

		local staged = Sift.Dictionary.copyDeep(currentData)
		local ok, result = pcall(step.apply, staged)
		if not ok then
			logger:log("error", "failed to apply migration step", { stepName = step.name, error = result })
			return Promise.reject(result)
		end

		currentData = Sift.Dictionary.copyDeep(result)
	end

	return currentData
end

return {
	Migration = Migration,
	validateMigrationSteps = validateMigrationSteps,
	applyMigrationSteps = applyMigrationSteps,
}
