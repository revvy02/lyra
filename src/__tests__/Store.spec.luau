local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Constants = require(ReplicatedStorage.Packages.Mix.Constants)
local DataStoreInterface = require(ReplicatedStorage.Packages.Mix.DataStoreInterface)
local Store = require(ReplicatedStorage.Packages.Mix.Store)

local it = JestGlobals.it
local expect = JestGlobals.expect

local function getStore()
	local mockInterface = DataStoreInterface.Mock.new()
	return Store.createStore({
		name = "test",
		template = {
			foo = "bar",
		},
		schema = function()
			return true
		end,
		dataStoreInterface = mockInterface,
	}),
		mockInterface
end
