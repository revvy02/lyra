local HttpService = game:GetService("HttpService")

local Types = require(script.Parent.Types)
local splitUtf8String = require(script.Parent.splitUtf8String)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)

local function isLargeFile(file: Types.File): boolean
	return file.shard ~= nil
end

export type WriteParams = {
	dataStoreInterface: Types.DataStoreInterface,
	data: any,
	maxShardSize: number,
	key: string,
	scope: string,
	userIds: { number }?,
}
export type WriteError = {
	error: string,
	file: Types.File,
}

local function write(params: WriteParams): Promise.TPromise<Types.File>
	local str = HttpService:JSONEncode(params.data)
	if #str <= params.maxShardSize then
		return Promise.resolve({ data = params.data } :: Types.File)
	end

	local shardId = HttpService:GenerateGUID(false)
	local shards = splitUtf8String(str, params.maxShardSize)
	local file = { shard = shardId, count = #shards }

	local shardPromises = Tables.map(shards, function(shard, index)
		return params.dataStoreInterface:set(params.scope, `{shardId}-{index}`, shard, params.userIds)
	end)

	return Promise.all(shardPromises):andThenReturn(file):catch(function(err)
		return Promise.reject({
			error = `Failed to write file: {err}`,
			file = file,
		})
	end)
end

export type ReadParams = {
	dataStoreInterface: Types.DataStoreInterface,
	scope: string,
	file: Types.File,
}

local function read(params: ReadParams): Promise.TPromise<any>
	if not isLargeFile(params.file) then
		return Promise.resolve(params.file.data)
	end

	local shardId = params.file.shard

	local promises = {}

	for i = 1, params.file.count do
		table.insert(promises, params.dataStoreInterface:get(params.scope, `{shardId}-{i}`))
	end

	return Promise.all(promises):andThen(function(shards)
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
end

return {
	isLargeFile = isLargeFile,
	write = write,
	read = read,
}
