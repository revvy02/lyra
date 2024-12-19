local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(script.Parent.Promise)

return function()
	local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI
	local processServiceExists, ProcessService = pcall(function()
		return (game :: any):GetService("ProcessService")
	end)

	return Promise.new(function(resolve, onCancel)
		local p = runCLI(ReplicatedStorage.Packages.Lyra, {
			verbose = true,
			ci = false,
		}, { ReplicatedStorage.Packages.Lyra })

		onCancel(function()
			p:cancel()
		end)

		local status, result = p:awaitStatus()

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

		resolve(result)
	end)
end
