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

type KeyOperationQueueItem = {
	resolve: () -> (),
	reject: (string) -> (),
	operation: () -> Promise.Promise,
}

type KeyOperationQueue = { KeyOperationQueueItem }

type UnsavedMutationsSnapshot = { [string]: boolean }

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
		_unsavedMutations = {},
		_keyOperationQueues = {},
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

function Store:_enqueueKeyOperation(key: string, operation: () -> Promise.Promise): Promise.Promise
	local queue = self._keyOperationQueues[key]
	if queue == nil then
		queue = {}
		self._keyOperationQueues[key] = queue
	end

	local resolve, reject
	local promise = Promise.new(function(_resolve, _reject)
		resolve = _resolve
		reject = _reject
	end)

	local info = {
		resolve = resolve,
		reject = reject,
		operation = operation,
	}

	table.insert(queue, info)

	if #queue == 1 then
		task.spawn(function()
			self:_processKeyOperationQueue(queue)
		end)
	end

	return promise
end

function Store:_enqueueMultiKeyOperation(keys: { string }, operation: () -> Promise.Promise): Promise.Promise
	local resolve
	local promise = Promise.new(function(_resolve)
		resolve = _resolve
	end):andThenCall(operation)

	local numReady = 0

	local promises = Sift.Array.map(keys, function(key)
		return self:_enqueueKeyOperation(key, function()
			numReady += 1
			if numReady == #keys then
				resolve()
			end
			return promise
		end)
	end)

	return Promise.all(promises)
end

function Store:_processKeyOperationQueue(queue: KeyOperationQueue): ()
	while #queue > 0 do
		local info = queue[1]

		-- TODO: timeout to notify of deadlock?
		Promise.try(info.operation):andThen(info.resolve, info.reject):finallyCall(table.remove, queue, 1):await()
	end
end

function Store:_getLock(): Types.Lock
	return {
		id = self._lockId,
		expiry = DateTime.now().UnixTimestamp + LOCK_DURATION_SECONDS,
	}
end

function Store:_getSnapshot(key: string): UnsavedMutationsSnapshot
	return Sift.Set.copy(self._unsavedMutations[key])
end

function Store:_isSnapshotCommitted(snapshot: UnsavedMutationsSnapshot, key: string): boolean
	local intersection = Sift.Set.intersection(snapshot, self._unsavedMutations[key])
	return Sift.Set.count(intersection) == 0
end

function Store:_commitSnapshot(snapshot: UnsavedMutationsSnapshot, key: string): ()
	self._unsavedMutations[key] = Sift.Set.difference(self._unsavedMutations[key], snapshot)
end

function Store:_isSaved(key: string): boolean
	return Sift.Set.count(self._unsavedMutations[key]) == 0
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

			-- TODO: migrations

			self._cache[key] = data
			self._unsavedMutations[key] = {}
			self._keyOperationQueues[key] = {}

			return data
		end)
end

function Store:unlock(key: string): Promise.Promise
	return self:_enqueueKeyOperation(key, function()
		local data = Sift.Dictionary.copyDeep(self._cache[key])
		local txInfo = { committedData = data }

		return self:_writeLargeFile(txInfo)
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
				self._unsavedMutations[key] = nil
				self._keyOperationQueues[key] = nil

				if latestValue.lock.id ~= nil then
					return Promise.reject("Failed to release lock")
				end

				return nil
			end)
	end)
end

function Store:_mutateKey(key: string, newData: any): ()
	local mutationId = HttpService:GenerateGUID(false)
	self._unsavedMutations[key] = Sift.Set.add(self._unsavedMutations[key], mutationId)
	self._cache[key] = newData
end

function Store:update(key: string, transformFunction: (data: any) -> any): Promise.Promise
	return Promise.new(function(resolve, reject)
		while self._txLockPromises[key] ~= nil do
			self._txLockPromises[key]:await()
		end

		local currentData = self._cache[key]
		local nextData = Sift.Dictionary.copyDeep(currentData)
		-- TODO: make it impossible for transformFunction to yield
		local transformOk, result = pcall(transformFunction, nextData)
		if not transformOk then
			return reject(`Store:update transformFunction failed: {result}`)
		end

		if result == nil then
			return resolve()
		end
		nextData = result

		if Sift.Dictionary.equalsDeep(nextData, currentData) then
			return resolve()
		end

		local schemaOk, err = self._schema(nextData)
		if not schemaOk then
			return reject(`Store:update schema validation failed: {err}`)
		end

		self:_mutateKey(key, nextData)

		return resolve()
	end)
end

function Store:tx(
	keys: { string },
	transformFunction: (state: { [string]: any }) -> { [string]: any }?
): Promise.Promise
	local txLockResolve
	local txLockPromise = Promise.new(function(_resolve)
		txLockResolve = _resolve
	end)

	return self:_enqueueMultiKeyOperation(keys, function()
		local currentState = {}
		for _, key in keys do
			self._txLockPromises[key] = txLockPromise
			currentState[key] = self._cache[key]
		end

		local nextState = Sift.Dictionary.copyDeep(currentState)
		-- TODO: make it impossible for transformFunction to yield
		local transformOk, result = pcall(transformFunction, nextState)
		if not transformOk then
			error(`Store:tx transformFunction failed: {result}`)
		end

		if result == nil then
			return
		end
		nextState = result

		if Sift.Dictionary.equalsDeep(nextState, currentState) then
			return
		end

		for _, key in keys do
			local schemaOk, err = self._schema(nextState[key])
			if not schemaOk then
				error(`Store:tx schema validation failed: {err}`)
			end
		end

		-- If no keys changed we can exit early, and if only one key changed, we
		-- can treat it as a normal :update.
		local changedKeys = Sift.Array.filter(keys, function(key)
			return not Sift.Dictionary.equalsDeep(currentState[key], nextState[key])
		end)

		if #changedKeys == 0 then
			return
		elseif #changedKeys == 1 then
			local key = changedKeys[1]
			self:_mutateKey(key, nextState[key])
			return
		end

		local txId = HttpService:GenerateGUID(false)

		local promises = Sift.Array.map(keys, function(key)
			local txInfo = {
				txId = txId,
				committedData = currentState[key],
				txData = nextState[key],
			}

			return self:_writeLargeFile(txInfo):andThen(function(file)
				local record = {
					lock = self:_getLock(),
					file = file,
				}

				return self._dataStoreInterface:update(Constants.RECORD_SCOPE, key, function(oldRecord)
					if oldRecord.lock.id ~= self._lockId then
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
				for _, key in keys do
					-- :tx is required to save, so we commit all unsaved
					-- mutations here
					local snapshot = self:_getSnapshot(key)
					self:_commitSnapshot(snapshot, key)
					self._cache[key] = nextState[key]
				end

				-- TODO: kick off cleanup process
			end)

		return commitPromise
	end):finally(function()
		for _, key in keys do
			if self._txLockPromises[key] == txLockPromise then
				self._txLockPromises[key] = nil
			end
		end
		txLockResolve()
	end)
end

function Store:save(key: string): Promise.Promise
	if self:_isSaved(key) then
		return Promise.resolve()
	end
	local snapshot = self:_getSnapshot(key)

	return self:_enqueueKeyOperation(function()
		if self:_isSnapshotCommitted(snapshot, key) then
			return
		end

		if self:_isSaved(key) then
			return
		end

		snapshot = self:_getSnapshot(key)

		local data = Sift.Dictionary.copyDeep(self._cache[key])
		local txInfo = { committedData = data }

		return self:_writeLargeFile(txInfo)
			:andThen(function(file)
				local record = {
					lock = self:_getLock(),
					file = file,
				}
				return self._dataStoreInterface:set(Constants.RECORD_SCOPE, key, record)
			end)
			:andThen(function()
				self:_commitSnapshot(snapshot, key)
			end)
	end)
end

return {
	createStore = createStore,
}
