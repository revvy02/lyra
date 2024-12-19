local ReplicatedStorage = game:GetService("ReplicatedStorage")

local runJestTests = require(ReplicatedStorage.Packages.Lyra.runJestTests)

runJestTests():expect()
