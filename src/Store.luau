local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LOCK_DURATION_SECONDS = 2 * 60

local Constants = require(script.Parent.Constants)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local DataStoreInterface = require(script.Parent.DataStoreInterface)
local Types = require(script.Parent.Types)
local splitUtf8String = require(script.Parent.splitUtf8String)

export type StoreConfig = {
	name: string,
	template: any,
	schema: (value: any) -> (boolean, string?),
	migrations: { [number]: (value: any) -> any }?,
	dataStoreInterface: Types.DataStoreInterface?,
}

local function awaitIfExists(promise: Promise.Promise?): Promise.Promise
	return Promise.new(function(resolve)
		if promise ~= nil then
			promise:await()
		end
		resolve()
	end)
end

local Store = {}

local function createStore(config: StoreConfig)
	local dataStoreInterface = config.dataStoreInterface or DataStoreInterface.Mock.new()

	local self = setmetatable({
		_name = config.name,
		_template = config.template,
		_schema = config.schema,
		_migrations = config.migrations or {},
		_dataStoreInterface = dataStoreInterface,
		_lockId = HttpService:GenerateGUID(false),
		_cache = {},
		_txLockPromises = {},
		_saveState = {},
	}, { __index = Store })

	local ok, err = self._schema(self._template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	return self
end

function Store:_writeLargeFile(data: any): Promise.TypedPromise<Types.File>
	local str = HttpService:JSONEncode(data)
	if #str <= Constants.MAX_CHUNK_SIZE then
		return Promise.resolve({ data = data } :: Types.File)
	end

	local shardId = HttpService:GenerateGUID(false)
	local shards = splitUtf8String(data, Constants.MAX_CHUNK_SIZE)

	local promises = Sift.Array.map(shards, function(shard, index)
		-- TODO: attach metadata so it can be cleaned up
		return self._dataStoreInterface:set(Constants.SHARD_SCOPE, `{shardId}-{index}`, shard)
	end)

	return Promise.all(promises):andThenReturn({ shard = shardId, count = #shards })
end

function Store:_readLargeFile(file: Types.File): Promise.TypedPromise<any>
	local shardId = file.shard
	if shardId == nil then
		return Promise.resolve(file.data)
	end

	local promises = {}

	for i = 1, file.count do
		table.insert(promises, self._dataStoreInterface:get(Constants.SHARD_SCOPE, `{shardId}-{i}`))
	end

	return Promise.all(promises):andThen(function(shards)
		return HttpService:JSONDecode(table.concat(shards))
	end)
end

function Store:_readTx(txInfo: Types.TxInfo): Promise.TypedPromise<any>
	local txId = txInfo.txId
	if txId == nil then
		return Promise.resolve(txInfo.committedData)
	end

	return self._dataStoreInterface:get(Constants.TX_SCOPE, txId):andThen(function(txStatus)
		if txStatus == "committed" then
			return txInfo.txData
		else
			return txInfo.committedData
		end
	end)
end

function Store:_getLock(): Types.Lock
	return {
		id = self._lockId,
		expiry = DateTime.now().UnixTimestamp + LOCK_DURATION_SECONDS,
	}
end

function Store:lock(key: string): Promise.Promise
	local function transformFunction(value)
		value = Sift.Dictionary.mergeDeep({ lock = {} }, value)

		local lock = value.lock
		if lock.expiry ~= nil and lock.expiry > DateTime.now().UnixTimestamp then
			return nil
		end

		value.lock = self:_getLock()

		return value
	end

	return self._dataStoreInterface
		:update(Constants.RECORD_SCOPE, key, transformFunction)
		:andThen(function(record)
			if record.lock.id ~= self._lockId then
				return Promise.reject("Failed to acquire lock")
			end

			local file = record.file
			if file == nil then
				return nil
			end

			return self:_readLargeFile(file)
		end)
		:andThen(function(txInfo)
			if txInfo == nil then
				return nil
			end

			return self:_readTx(txInfo)
		end)
		:andThen(function(data)
			if data == nil then
				data = Sift.Dictionary.copyDeep(self._template)
			end

			self._cache[key] = data
			self._saveState[key] = {
				unsavedMutations = {},
				savePromise = nil,
			}

			return data
		end)
end

function Store:unlock(key: string): Promise.Promise
	local data = Sift.Dictionary.copyDeep(self._cache[key])
	local txInfo = { committedData = data }

	return awaitIfExists(self._txLockPromises[key])
		:andThen(function()
			return self:_writeLargeFile(txInfo)
		end)
		:andThen(function(file)
			local record = {
				lock = {
					id = nil,
					expiry = nil,
				},
				file = file,
			}

			local function transformFunction(value)
				if value.lock.id == self._lockId then
					return record
				else
					return nil
				end
			end

			return self._dataStoreInterface:update(Constants.RECORD_SCOPE, key, transformFunction)
		end)
		:andThen(function(latestValue)
			self._cache[key] = nil
			self._saveState[key] = nil

			if latestValue.lock.id ~= nil then
				return Promise.reject("Failed to release lock")
			end

			return nil
		end)
end

function Store:update(key: string, transformFunction: (data: any) -> any): Promise.Promise
	return awaitIfExists(self._txLockPromises[key]):andThen(function()
		local currentData = self._cache[key]
		local nextData = Sift.Dictionary.copyDeep(currentData)
		-- TODO: make it impossible for transformFunction to yield
		local transformOk, result = pcall(transformFunction, nextData)
		if not transformOk then
			error(`Store:update transformFunction failed: {result}`)
		end

		if result == nil then
			return
		end
		nextData = result

		if Sift.Dictionary.equalsDeep(nextData, currentData) then
			return
		end

		local schemaOk, err = self._schema(nextData)
		if not schemaOk then
			error(`Store:update schema validation failed: {err}`)
		end

		local mutationId = HttpService:GenerateGUID(false)

		self._saveState[key].unsavedMutations = Sift.Set.add(self._saveState[key].unsavedMutations, mutationId)
		self._cache[key] = nextData
	end)
end

function Store:tx(
	keys: { string },
	transformFunction: (state: { [string]: any }) -> { [string]: any }?
): Promise.Promise
	local currentState = {}
	for _, key in keys do
		if self._txLockPromises[key] ~= nil then
			return Promise.reject("Attempt to run a tx while another is in progress")
		end

		currentState[key] = self._cache[key]
	end

	local nextState = Sift.Dictionary.copyDeep(currentState)
	-- TODO: make it impossible for transformFunction to yield
	local transformOk, result = pcall(transformFunction, nextState)
	if not transformOk then
		error(`Store:tx transformFunction failed: {result}`)
	end

	if result == nil then
		return Promise.resolve()
	end
	nextState = result

	if Sift.Dictionary.equalsDeep(nextState, currentState) then
		return Promise.resolve()
	end

	for _, key in keys do
		local schemaOk, err = self._schema(nextState[key])
		if not schemaOk then
			error(`Store:tx schema validation failed: {err}`)
		end
	end

	local txId = HttpService:GenerateGUID(false)
	-- local mutationId = HttpService:GenerateGUID(false)

	-- TODO: check if no keys changed, if so, return early
	-- TODO: check if only one key changed, treat it as just an :update

	local promises = Sift.Array.map(keys, function(key)
		local committedData = currentState[key]
		local txData = nextState[key]

		local txInfo = {
			txId = txId,
			committedData = committedData,
			txData = txData,
		}

		return self:_writeLargeFile(txInfo):andThen(function(file)
			local record = {
				lock = self:_getLock(),
				file = file,
			}

			return self._dataStoreInterface:update(Constants.RECORD_SCOPE, key, function(value)
				if value.lock.id ~= self._lockId then
					return nil
				end

				return record
			end)
		end)
	end)

	local commitPromise = Promise.all(promises)
		:andThen(function()
			-- TODO: attach metadata so it can be cleaned up
			return self._dataStoreInterface:set(Constants.TX_SCOPE, txId, {
				status = "committed",
			})
		end)
		:andThen(function()
			-- TODO: this counts as a save - we shouldn't add a mutation, we
			-- should snapshot the mutations at the start of the tx and flush
			-- them here like Store:save
			for _, key in keys do
				-- self._saveState[key].unsavedMutations = Sift.Set.add(self._saveState[key].unsavedMutations, mutationId)

				-- TODO: take a snapshot of unsavedMutations before and after,
				-- compare, and error if they're different. :update should never
				-- run during a tx

				self._cache[key] = nextState[key]
			end

			-- TODO: kick off cleanup process
		end)
		:finally(function()
			for _, key in keys do
				self._txLockPromises[key] = nil
			end
		end)

	for _, key in keys do
		self._txLockPromises[key] = commitPromise
	end

	return commitPromise
end

function Store:save(key: string): Promise.Promise
	-- By keeping track of mutations made to the data, we can easily use that to
	-- determine when every mutation that's taken place as of this function call
	-- has been saved.

	-- TODO: should we wait for tx lock here before saving since tx counts as a
	-- save?

	local saveState = self._saveState[key]
	if Sift.Set.count(saveState.unsavedMutations) == 0 then
		return Promise.resolve()
	end

	-- We take a snapshot of unsaved mutations to:
	-- 1. Remove them from the list when our save finishes
	-- 2. If a save is in progress, check if we need even need to save again
	local snapshot = Sift.Set.copy(saveState.unsavedMutations)

	return Promise.new(function(resolve)
		while saveState.savePromise ~= nil do
			saveState.savePromise:await()
		end

		local intersection = Sift.Set.intersection(snapshot, saveState.unsavedMutations)
		if Sift.Set.count(intersection) == 0 then
			return resolve()
		end

		snapshot = Sift.Set.copy(saveState.unsavedMutations)

		if Sift.Set.count(snapshot) == 0 then
			return resolve()
		end

		local data = Sift.Dictionary.copyDeep(self._cache[key])
		local txInfo = { committedData = data }

		local savePromise = self._largeFileManager
			:write(txInfo)
			:andThen(function(file)
				local record = {
					lock = self:_getLock(),
					file = file,
				}
				return self._dataStoreInterface:set(Constants.RECORD_SCOPE, key, record)
			end)
			:andThen(function()
				saveState.unsavedMutations = Sift.Set.difference(saveState.unsavedMutations, snapshot)
			end)
			:finally(function()
				saveState.savePromise = nil
			end)

		saveState.savePromise = savePromise

		return resolve(savePromise)
	end)
end

return {
	createStore = createStore,
}
