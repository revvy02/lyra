--!strict

local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)
local Types = require(script.Parent.Types)

type Data = { [string]: any }

local function validate(steps: { Types.MigrationStep })
	assert(typeof(steps) == "table", "steps must be a table")
	for _, step in steps do
		assert(typeof(step) == "table", "step must be a table")
		assert(typeof(step.name) == "string", "step.name must be a string")
		assert(typeof(step.apply) == "function", "step.apply must be a function")
	end
end

local function makeAddFieldsStep(name: string, fields: Data): Types.MigrationStep
	return {
		name = name,
		apply = function(data)
			return Tables.mergeDeep(fields, data)
		end,
	}
end

local function makeTransformStep(name: string, transformFunc: (currentValue: Data) -> Data): Types.MigrationStep
	return {
		name = name,
		apply = transformFunc,
	}
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

local function apply(params: ApplyParams): Promise.TPromise<ApplyResult>
	local logger = params.logger
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

				local staged = Tables.copyDeep(currentData)
				local ok, result = pcall(step.apply, staged)
				if not ok then
					logger:log("error", "failed to apply migration step", { stepName = step.name, error = result })
					return reject(result)
				end

				currentData = Tables.copyDeep(result)
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
	makeAddFieldsStep = makeAddFieldsStep,
	makeTransformStep = makeTransformStep,
	validate = validate,
	apply = apply,
	getStepNames = getStepNames,
}
