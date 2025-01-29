--!strict

local HttpService = game:GetService("HttpService")

local Types = require(script.Parent.Types)
local splitUtf8String = require(script.Parent.splitUtf8String)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)
local dataStoreRetry = require(script.Parent.dataStoreRetry)

local function isLargeFile(file: Types.File): boolean
	return file.shard ~= nil
end

export type WriteParams = {
	store: DataStore,
	data: any,
	maxShardSize: number,
	key: string,
	userIds: { number }?,
}
export type WriteError = {
	error: string,
	file: Types.File,
}

local function write(params: WriteParams): Promise.TPromise<Types.File>
	local dataEncoded = HttpService:JSONEncode(params.data)
	if #dataEncoded <= params.maxShardSize then
		return Promise.resolve({ data = params.data } :: Types.File)
	end

	local dataCompressed = HttpService:JSONEncode(buffer.fromstring(dataEncoded))
	local shards = splitUtf8String(dataCompressed, params.maxShardSize)

	local shardId = HttpService:GenerateGUID(false)
	local file = { shard = shardId, count = #shards }

	local shardPromises = Tables.map(shards, function(shard, index)
		return dataStoreRetry(function()
			return params.store:SetAsync(`{shardId}-{index}`, shard, params.userIds)
		end)
	end)

	return Promise.all(shardPromises):andThenReturn(file):catch(function(err)
		return Promise.reject({
			error = `Failed to write file: {err}`,
			file = file,
		})
	end)
end

export type ReadParams = {
	store: DataStore,
	file: Types.File,
}

local function read(params: ReadParams): Promise.TPromise<any>
	if not isLargeFile(params.file) then
		return Promise.resolve(params.file.data)
	end

	local shardId = params.file.shard

	local promises = {}

	for i = 1, params.file.count do
		table.insert(
			promises,
			dataStoreRetry(function()
				return params.store:GetAsync(`{shardId}-{i}`)
			end)
		)
	end

	return Promise.all(promises)
		:andThen(function(shards)
			for i = 1, params.file.count do
				if shards[i] == nil then
					return Promise.reject(`Missing shard {i} for file {shardId}`)
				end
			end

			local ok, result = pcall(function()
				return HttpService:JSONDecode(table.concat(shards))
			end)
			return if ok then result else Promise.reject(`Error decoding file: {result}`)
		end)
		:andThen(function(dataCompressed)
			local dataDecoded = HttpService:JSONDecode(buffer.tostring(dataCompressed))
			return dataDecoded
		end)
end

return {
	isLargeFile = isLargeFile,
	write = write,
	read = read,
}
