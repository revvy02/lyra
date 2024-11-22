--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Types)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

local Dictionary = Sift.Dictionary

export type MigrateDataParams = {
	fromVersion: number,
	toVersion: number,
	data: any,
	migrations: { (data: any) -> any },
}

local function migrateData(params: MigrateDataParams): Promise.TypedPromise<any>
	local data = Dictionary.copyDeep(params.data)

	return Promise.new(function(resolve, reject)
		for i = params.fromVersion + 1, params.toVersion do
			local migration = params.migrations[i]
			if not migration then
				return reject(`No migration found for version {i}`)
			end

			local resolved, result = Promise.try(migration, data):await()
			if not resolved then
				return reject(`Migration failed for version {i}: {result}`)
			end

			data = Dictionary.copyDeep(result)
		end

		resolve(data)
	end)
end

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
	migrateData = migrateData,
	readTx = readTx,
}
