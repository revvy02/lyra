local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local it = JestGlobals.it
local expect = JestGlobals.expect

it("say hi", function()
	expect("hi").toBe("hi")
end)
