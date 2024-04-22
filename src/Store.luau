local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(script.Parent.Constants)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local DataStoreInterface = require(script.Parent.DataStoreInterface)
local LargeFileManager = require(script.Parent.LargeFileManager)
local LockManager = require(script.Parent.LockManager)
local TransactionManager = require(script.Parent.TransactionManager)
local Types = require(script.Parent.Types)

export type StoreConfig = {
	name: string,
	template: any,
	schema: (value: any) -> (boolean, string?),
	migrations: { [number]: (value: any) -> any }?,
	dataStoreInterface: Types.DataStoreInterface?,
}

local Store = {}

local function createStore(config: StoreConfig)
	local dataStoreInterface = config.dataStoreInterface or DataStoreInterface.Mock.new()
	local lockManager = LockManager.new(dataStoreInterface)
	local largeFileManager = LargeFileManager.new(dataStoreInterface)
	local transactionManager = TransactionManager.new(dataStoreInterface)

	local self = setmetatable({
		_name = config.name,
		_template = config.template,
		_schema = config.schema,
		_migrations = config.migrations or {},
		_cache = {},
		_dataStoreInterface = dataStoreInterface,
		_lockManager = lockManager,
		_largeFileManager = largeFileManager,
		_transactionManager = transactionManager,
		_saveState = {},
	}, { __index = Store })

	local ok, err = self._schema(self._template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	return self
end

function Store:lock(key: string)
	return self._lockManager:lock(key):andThen(function(record)
		local data = self._deserialize(record):expect()
		if data == nil then
			data = Sift.Dictionary.copyDeep(self._template)
		end

		record.data = data

		self._cache[key] = record
		self._saveState[key] = {
			unsavedMutations = Sift.Set.fromArray({}),
			savePromise = nil,
		}

		return data
	end)
end

function Store:unlock(key: string)
	return self._lockManager:unlock(key):andThen(function()
		self._cache[key] = nil
		self._saveState[key] = nil
	end)
end

function Store:update(key: string, transformFunction: (value: any) -> any)
	local currentState = self._cache[key].data
	local nextState = Sift.Dictionary.copyDeep(currentState)
	local transformOk, result = pcall(transformFunction, nextState)
	if not transformOk then
		error(`Store:update transformFunction failed: {result}`)
	end

	if result == nil then
		return
	end
	nextState = result

	if Sift.Dictionary.equalsDeep(nextState, currentState) then
		return
	end

	local schemaOk, err = self._schema(nextState)
	if not schemaOk then
		error(`Store:update schema validation failed: {err}`)
	end

	local mutationId = HttpService:GenerateGUID(false)

	Sift.Set.add(self._saveState[key].unsavedMutations, mutationId)
	self._cache[key].data = Sift.Dictionary.mergeDeep(currentState, nextState)
end

function Store:_deserialize(record: Types.DataStoreRecord)
	self._transactionManager:read(record):andThen(function(dataChunk: Types.DataChunk)
		return self._largeFileManager:read(dataChunk)
	end)
end

function Store:_serialize(key: string): Promise.TypedPromise<Types.DataStoreRecord>
	return Promise.new(function(resolve)
		local record = Sift.Dictionary.copyDeep(self._cache[key])
		local data = record.data
		local shardId, shardCount = self._largeFileManager:write(data):expect()
		if shardId then
			data = {
				shard = shardId,
				count = shardCount,
			}
		else
			data = {
				data = data,
			}
		end

		record.data = data
		record = self._lockManager:refreshLockExpiry(record)
		return resolve(record)
	end)
end

function Store:save(key: string)
	-- By keeping track of mutations made to the data, we can easily use that to
	-- determine when every mutation that's taken place as of this function call
	-- has been saved.

	local saveState = self._saveState[key]
	if Sift.Set.count(saveState.unsavedMutations) == 0 then
		return saveState.savePromise or Promise.resolve()
	end

	-- We take a snapshot of unsaved mutations to:
	-- 1. Remove them from the list when our save finishes
	-- 2. If a save is in progress, check if we need even need to save again
	local snapshot = Sift.Set.copy(saveState.unsavedMutations)

	return Promise.resolve(saveState.savePromise):andThen(function()
		local intersection = Sift.Set.intersection(snapshot, saveState.unsavedMutations)
		if Sift.Set.count(intersection) == 0 then
			return
		end

		snapshot = Sift.Set.copy(saveState.unsavedMutations)

		if Sift.Set.count(snapshot) == 0 then
			return
		end

		local savePromise = Promise.new(function(resolve)
			local record = self:_serialize(key):expect()
			self._dataStoreInterface:set(Constants.RECORD_SCOPE, key, record):expect()

			saveState.unsavedMutations = Sift.Array.difference(saveState.unsavedMutations, snapshot)
			saveState.savePromise = nil
			resolve()
		end)

		saveState.savePromise = savePromise

		return savePromise
	end)
end

return {
	createStore = createStore,
}
