--!strict

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
			return txInfo.txData
		else
			return txInfo.committedData
		end
	end)
end

return {
	readTx = readTx,
}
