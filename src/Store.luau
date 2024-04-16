local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sift = require(ReplicatedStorage.Packages.Sift)
local DataStoreInterface = require(script.Parent.DataStoreInterface)
local LockManager = require(script.Parent.LockManager)
local Types = require(script.Parent.Types)

export type StoreConfig = {
	name: string,
	template: any,
	schema: (value: any) -> (boolean, string?),
	migrations: { [number]: (value: any) -> any }?,
	dataStoreInterface: Types.DataStoreInterface?,
}

local Store = {}

local function createStore(config: StoreConfig)
	local dataStoreInterface = config.dataStoreInterface or DataStoreInterface.Mock.new()
	local lockManager = LockManager.new(dataStoreInterface)

	local self = setmetatable({
		_name = config.name,
		_template = config.template,
		_schema = config.schema,
		_migrations = config.migrations or {},
		_cache = {},
		_dataStoreInterface = dataStoreInterface,
		_lockManager = lockManager,
	}, Store)

	local ok, err = self._schema(self._template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	return self
end

function Store:lock(key: string)
	return self._lockManager:lock(key)
end

function Store:unlock(key: string)
	return self._lockManager:unlock(key)
end

function Store:update(key: string, transformFunction: (value: any) -> any)
	local currentState = Sift.Dictionary.copyDeep(self._cache[key].data)
	local transformOk, result = pcall(transformFunction, currentState)
	if not transformOk then
		error(`Store:update transformFunction failed: {result}`)
	end

	local nextState = result
	if nextState == nil then
		return
	end

	local schemaOk, err = self._schema(nextState)
	if not schemaOk then
		error(`Store:update schema validation failed: {err}`)
	end

	self._cache[key].data = nextState
end

return {
	createStore = createStore,
}
