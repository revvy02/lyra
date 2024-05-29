local noYield = require(script.Parent.noYield)

local function migrationsFromFolder(folder: Folder): { [number]: (value: { [string]: any }) -> { [string]: any } }
	local migrations = {}

	for _, module in folder:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end

		assert(module.Name:match("^%d+$"), `Invalid migration module name: {module.Name}`)

		local version = tonumber(module.Name)
		if version == nil then
			error(`Invalid migration module name: {module.Name}`)
		end

		local ok, result = pcall(noYield, function()
			return require(module)
		end)
		if not ok then
			error(`Error requiring migration module "{module.Name}": {result}`)
		end

		assert(typeof(result) == "function", `Migration module "{module.Name}" must return a function`)
		migrations[version] = result
	end

	local lastVersion = 1
	for version in migrations do
		assert(version == lastVersion + 1, `Missing migration version: {lastVersion + 1}`)
		lastVersion = version
	end

	return migrations
end

return migrationsFromFolder
