return {
	setupFilesAfterEnv = { script.Parent.__tests__.setupJest },
	testMatch = { "**/*.spec" },
	testPathIgnorePatterns = if workspace:GetAttribute("SimulationTests") ~= true then { "Simulation" } else {},
}
