local ReplicatedStorage = game:GetService("ReplicatedStorage")

_G.NOCOLOR = true
local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI

local processServiceExists, ProcessService = pcall(function()
	return game:GetService("ProcessService")
end)

local status, result = runCLI(ReplicatedStorage.Packages.Lyra, {
	verbose = true,
	ci = false,
}, { ReplicatedStorage.Packages.Lyra }):awaitStatus()

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

return nil
