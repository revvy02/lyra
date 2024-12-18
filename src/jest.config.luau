return {
	testMatch = { "**/*.spec" },
	testPathIgnorePatterns = if workspace:GetAttribute("SimulationTests") ~= true then { "Simulation" } else {},
}
