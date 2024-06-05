local ReplicatedStorage = game:GetService("ReplicatedStorage")

_G.NOCOLOR = true
local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI

local processServiceExists, ProcessService = pcall(function()
	return game:GetService("ProcessService")
end)

local status, result = runCLI(ReplicatedStorage.Packages.Mix, {
	verbose = true,
	ci = false,
}, { ReplicatedStorage.Packages.Mix }):awaitStatus()

if status == "Rejected" then
	print(result)
end

if status == "Resolved" and result.results.numFailedTestSuites == 0 and result.results.numFailedTests == 0 then
	if processServiceExists then
		ProcessService:ExitAsync(0)
	end
end

if processServiceExists then
	ProcessService:ExitAsync(1)
end

-- local Mix = require(ReplicatedStorage.Packages.Mix)
-- local store = Mix.createPlayerStore({
-- 	name = `test`,
-- 	template = {},
-- 	schema = function()
-- 		return true
-- 	end,
-- })

-- store:lock(123):expect()
-- store
-- 	:update(123, function(data)
-- 		data.foo = "bar"
-- 		return data
-- 	end)
-- 	:expect()
-- store:unlock(123):expect()
-- print(store:lock(123):expect())

return nil
