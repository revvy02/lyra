local Workspace = game:GetService("Workspace")

return {
	testMatch = { "**/*.spec" },
	testPathIgnorePatterns = if Workspace:GetAttribute("SimulationTests") ~= true then { "Simulation" } else {},
}
