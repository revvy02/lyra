--!strict

local JsonPatch = require(script.Parent.JsonPatch)
local Types = require(script.Parent.Types)
local Promise = require(script.Parent.Promise)
local dataStoreRetry = require(script.Parent.dataStoreRetry)

export type ReadTxParams = {
	store: DataStore,
	txInfo: Types.TxInfo,
}

local function readTx(params: ReadTxParams): Promise.TPromise<any>
	local txInfo = params.txInfo

	local txId = txInfo.txId
	if txId == nil then
		return Promise.resolve(txInfo.committedData)
	end

	return dataStoreRetry(function()
		return params.store:GetAsync(txId)
	end):andThen(function(txStatus)
		-- To minimize boundless growth, we consider a tx to be committed if its
		-- value is `nil`. Failed or in-progress txs are stored as `false`.
		if txStatus == nil then
			if txInfo.txPatch == nil then
				return Promise.reject("Tx is committed but has no patch")
			end
			return JsonPatch.applyPatch(txInfo.committedData, txInfo.txPatch)
		else
			return txInfo.committedData
		end
	end)
end

return {
	readTx = readTx,
}
