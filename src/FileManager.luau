local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataStoreInterface = require(script.Parent.DataStoreInterface)
local Types = require(script.Parent.Types)
local splitUtf8String = require(script.Parent.splitUtf8String)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

local Array = Sift.Array

local FileManager = {}

function FileManager.isLargeFile(file: Types.File): boolean
	return file.shard ~= nil
end

export type WriteOptions = {
	dataStoreInterface: DataStoreInterface.DataStoreInterface,
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

function FileManager.write(opts: WriteOptions): Promise.TypedPromise<Types.File>
	local str = HttpService:JSONEncode(opts.data)
	if #str <= opts.maxShardSize then
		return Promise.resolve({ data = opts.data } :: Types.File)
	end

	local shardId = HttpService:GenerateGUID(false)
	-- TODO: Add a test case ensuring that splitUtf8String is called with the correct arguments
	local shards = splitUtf8String(str, opts.maxShardSize)
	local file = { shard = shardId, count = #shards }

	local shardPromises = Array.map(shards, function(shard, index)
		return opts.dataStoreInterface:set(opts.scope, `{shardId}-{index}`, shard, opts.userIds)
	end)

	return Promise.all(shardPromises):andThenReturn(file):catch(function(err)
		return Promise.reject({
			error = `Failed to write file: {err}`,
			file = file,
		})
	end)
end

export type ReadOptions = {
	dataStoreInterface: DataStoreInterface.DataStoreInterface,
	scope: string,
	file: Types.File,
}

function FileManager.read(opts: ReadOptions): Promise.TypedPromise<any>
	if not FileManager.isLargeFile(opts.file) then
		return Promise.resolve(opts.file.data)
	end

	local shardId = opts.file.shard

	local promises = {}

	for i = 1, opts.file.count do
		table.insert(promises, opts.dataStoreInterface:get(opts.scope, `{shardId}-{i}`))
	end

	return Promise.all(promises):andThen(function(shards)
		local ok, result = pcall(function()
			return HttpService:JSONDecode(table.concat(shards))
		end)
		return if ok then result else Promise.reject(`Error decoding file: {result}`)
	end)
end

return FileManager
