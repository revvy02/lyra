local DataStoreInterface = require(script.Parent.DataStoreInterface)
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
	local self = setmetatable({
		_name = config.name,
		_template = config.template,
		_schema = config.schema,
		_migrations = config.migrations or {},
		_dataStoreInterface = config.dataStoreInterface or DataStoreInterface.Mock.new(),
	}, Store)

	local ok, err = self._schema(self._template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	return self
end

return {
	createStore = createStore,
}
