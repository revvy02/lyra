local Cases = script.Cases

local function runCase(case: ModuleScript)
	local caseModule = require(case)
	task.spawn(caseModule.run)
end

local function run()
	runCase(Cases.TDSMigrate)
end

return {
	run = run,
}
