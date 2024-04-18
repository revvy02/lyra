local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
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

function TransactionManager:read(record: Types.DataStoreRecord)
	local txId = record._metadata.tx_id
	if txId == nil then
		record = Sift.Dictionary.mergeDeep({ data = {} }, record)
		return record.data.committed_data
	end

	return self._dataStoreInterface:get(Constants.TX_SCOPE, txId):andThen(function(txStatus)
		if txStatus == "committed" then
			return record.data.tx_data
		else
			return record.data.committed_data
		end
	end)
end

function TransactionManager:write(records: { Types.DataStoreRecord }, txData: { Types.DataChunk })
	local txId = HttpService:GenerateGUID(false)

	records = Sift.Dictionary.map(records, function(record, key)
		record._metadata.tx_id = txId
		record.data.tx_data = txData[key]
		return record
	end)

	local promises = Sift.Dictionary.map(records, function(record, key)
		return self._dataStoreInterface:set(Constants.RECORD_SCOPE, key, record)
	end)

	return Promise.all(promises)
		:andThen(function()
			return self._dataStoreInterface:set(Constants.TX_SCOPE, txId, {
				status = "committed",
			})
		end)
		:andThen(function()
			return Sift.Dictionary.map(records, function(record)
				record._metadata.tx_id = nil
				record.data.committed_data = record.data.tx_data
				record.data.tx_data = nil
				return record
			end)
		end)
end

return TransactionManager
