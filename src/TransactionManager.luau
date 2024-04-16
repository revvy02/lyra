local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sift = require(ReplicatedStorage.Packages.Sift)
local Constants = require(script.Parent.Constants)
local Types = require(script.Parent.Types)

local TransactionManager = {}
TransactionManager.__index = TransactionManager

function TransactionManager.new(dataStoreInterface: Types.DataStoreInterface)
	local self = setmetatable({
		_dataStoreInterface = dataStoreInterface,
	}, TransactionManager)
	return self
end

function TransactionManager:read(value: any)
	local txId = value._metadata.tx_id
	if txId == nil then
		value = Sift.Dictionary.mergeDeep({ data = {} }, value)
		return value.data.committed_data
	end

	return self._dataStoreInterface:get(Constants.TX_SCOPE, txId):andThen(function(txValue)
		local status = txValue.status
		if status == "committed" then
			return value.data.tx_data
		else
			return value.data.committed_data
		end
	end)
end

return TransactionManager
