--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Types)
local Promise = require(ReplicatedStorage.Packages.Promise)

export type ReadTxParams = {
	dataStoreInterface: Types.DataStoreInterface,
	scope: string,
	txInfo: Types.TxInfo,
}

local function readTx(params: ReadTxParams): Promise.TypedPromise<any>
	local txInfo = params.txInfo

	local txId = txInfo.txId
	if txId == nil then
		return Promise.resolve(txInfo.committedData)
	end

	return params.dataStoreInterface:get(params.scope, txId):andThen(function(committed)
		-- To save on storage space, we consider a tx to be committed if its
		-- value is `nil`. Failed or in-progress txs are stored as `false`.
		if committed == nil then
			return txInfo.txData
		else
			return txInfo.committedData
		end
	end)
end

return {
	readTx = readTx,
}
