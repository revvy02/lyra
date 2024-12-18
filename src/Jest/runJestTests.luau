local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function()
	local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI
	local processServiceExists, ProcessService = pcall(function()
		return (game :: any):GetService("ProcessService")
	end)

	local status, result = runCLI(ReplicatedStorage.Packages.Lyra, {
		verbose = true,
		ci = false,
	}, { ReplicatedStorage.Packages.Lyra }):awaitStatus()

	if status == "Rejected" then
		warn(result)
	end

	if status == "Resolved" and result.results.numFailedTestSuites == 0 and result.results.numFailedTests == 0 then
		if processServiceExists then
			ProcessService:ExitAsync(0)
		end
	end

	if processServiceExists then
		ProcessService:ExitAsync(1)
	end
end
