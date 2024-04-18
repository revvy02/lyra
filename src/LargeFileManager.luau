local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local Constants = require(script.Parent.Constants)
local Types = require(script.Parent.Types)

local LargeFileManager = {}
LargeFileManager.__index = LargeFileManager

function LargeFileManager.new(dataStoreInterface: Types.DataStoreInterface)
	local self = setmetatable({
		_dataStoreInterface = dataStoreInterface,
	}, LargeFileManager)
	return self
end

-- TODO: implement this function
local function splitUtf8(str: string, maxSize: number) end

function LargeFileManager:read(dataChunk: Types.DataChunk): Promise.TypedPromise<any>
	local shardId = dataChunk.shard
	if shardId == nil then
		return dataChunk.data
	end

	local promises = {}

	for i = 1, dataChunk.count do
		table.insert(promises, self._dataStoreInterface:get(Constants.SHARD_SCOPE, `{shardId}-{i}`))
	end

	return Promise.all(promises):andThen(function(shards)
		return HttpService:JSONDecode(table.concat(shards))
	end)
end

function LargeFileManager:write(dataChunk: Types.DataChunk): Promise.TypedPromise<(string, number)>
	local shardId = HttpService:GenerateGUID(false)
	local shards = splitUtf8(dataChunk.data, Constants.MAX_CHUNK_SIZE)

	local promises = Sift.Array.map(shards, function(shard, index)
		-- TODO: attach metadata so it can be cleaned up
		return self._dataStoreInterface:set(Constants.SHARD_SCOPE, `{shardId}-{index}`, shard)
	end)

	return Promise.all(promises):andThenReturn(shardId, #shards)
end

return LargeFileManager
