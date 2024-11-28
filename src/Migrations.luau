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

local function validate(steps: { Types.MigrationStep })
	assert(typeof(steps) == "table", "steps must be a table")
	for _, step in steps do
		assert(typeof(step) == "table", "step must be a table")
		assert(typeof(step.name) == "string", "step.name must be a string")
		assert(typeof(step.apply) == "function", "step.apply must be a function")
	end
end

export type ApplyParams = {
	logger: Types.Logger,
	data: Data,
	steps: { Types.MigrationStep },
	appliedMigrations: { string },
}

export type ApplyResult = {
	data: Data,
	appliedMigrations: { string },
}

local function apply(params: ApplyParams): Promise.TypedPromise<ApplyResult>
	local logger = params.logger:extend({ method = "applyMigrations" })
	local currentData = params.data
	local appliedMigrations = params.appliedMigrations

	local appliedSet = {}
	for _, name in appliedMigrations do
		appliedSet[name] = true
	end

	return Promise.new(function(resolve, reject)
		for _, step in params.steps do
			if not appliedSet[step.name] then
				logger:log("trace", "applying migration step", { stepName = step.name })

				local staged = Sift.Dictionary.copyDeep(currentData)
				local ok, result = pcall(step.apply, staged)
				if not ok then
					logger:log("error", "failed to apply migration step", { stepName = step.name, error = result })
					return reject(result)
				end

				currentData = Sift.Dictionary.copyDeep(result)
				table.insert(appliedMigrations, step.name)
			end
		end

		return resolve({
			data = currentData,
			appliedMigrations = appliedMigrations,
		})
	end)
end

local function getStepNames(migrations: { Types.MigrationStep }): { string }
	local names = {}
	for _, step in migrations do
		table.insert(names, step.name)
	end
	return names
end

return {
	Migration = Migration,
	validate = validate,
	apply = apply,
	getStepNames = getStepNames,
}
