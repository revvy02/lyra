--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LOCK_DURATION_SECONDS = 2 * 60

local Constants = require(script.Parent.Constants)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local t = require(ReplicatedStorage.Packages.t)
local Types = require(script.Parent.Types)
local splitUtf8String = require(script.Parent.splitUtf8String)
local noYield = require(script.Parent.noYield)
local wrapPromiseFunc = require(script.Parent.wrapPromiseFunc)

export type StoreConfig = {
	name: string,
	template: any,
	schema: (value: any) -> (boolean, string?),
	migrations: { [number]: (value: any) -> any }?,
	dataStoreInterface: Types.DataStoreInterface?,
}
local storeConfigCheck = t.strictInterface({
	name = t.string,
	template = t.any,
	schema = t.callback,
	migrations = t.optional(t.array(t.callback)),
	dataStoreInterface = t.optional(t.table),
})

type KeyOperationQueueItem = {
	resolve: () -> (),
	reject: (string) -> (),
	operation: () -> Promise.Promise,
}

type KeyOperationQueue = { KeyOperationQueueItem }

type UnsavedMutationsSnapshot = { [string]: boolean }
local unsavedMutationsSnapshotCheck = t.map(t.string, t.boolean)

local function isLargeFile(file: Types.File): boolean
	return file.shard ~= nil
end

local Store = {}

local function createStore(config: StoreConfig)
	local dataStoreInterface = config.dataStoreInterface
	assert(dataStoreInterface, "dataStoreInterface is required")

	local self = setmetatable({
		_name = config.name,
		_template = config.template,
		_schema = config.schema,
		_migrations = config.migrations or {},
		_dataStoreInterface = dataStoreInterface,
		_lockId = HttpService:GenerateGUID(false),
		_keyInfo = {},
		_txLockPromises = {},
		_keyOperationQueues = {},
		_orphanedShards = {},
	}, { __index = Store })

	local ok, err = self._schema(self._template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	return self
end
createStore = t.wrap(createStore, t.tuple(storeConfigCheck))

function Store:_markOrphanedShards(...: Types.File)
	for _, file in { ... } do
		local isPresent = Sift.Array.findWhere(self._orphanedShards, function(otherFile)
			return Sift.Dictionary.equals(file, otherFile)
		end)
		if not isPresent then
			table.insert(self._orphanedShards, file)
		end
	end
end

function Store:_writeLargeFile(
	key: string,
	data: any,
	userIds: { number }?,
	metadata: { [string]: any }?
): Promise.TypedPromise<Types.File>
	local str = HttpService:JSONEncode(data)
	if #str <= Constants.MAX_CHUNK_SIZE then
		return Promise.resolve({ data = data } :: Types.File)
	end

	local shardId = HttpService:GenerateGUID(false)
	local shards = splitUtf8String(data, Constants.MAX_CHUNK_SIZE)

	local promises = Sift.Array.map(shards, function(shard, index)
		return self._dataStoreInterface:set(Constants.SHARD_SCOPE, `{shardId}-{index}`, shard, userIds, metadata)
	end)

	local file = { shard = shardId, count = #shards }

	local p = Promise.all(promises):andThenReturn(file):catch(function(err)
		table.insert(self._keyInfo[key].orphanedShards, file)
		self:_markOrphanedShards(file)
		return Promise.reject(err)
	end)

	return p
end
Store._writeLargeFile = wrapPromiseFunc(
	Store._writeLargeFile,
	t.tuple(t.any, t.string, t.any, t.optional(t.array(t.number)), t.optional(t.map(t.string, t.any))),
	t.tuple(Types.fileCheck)
)

function Store:_readLargeFile(file: Types.File): Promise.TypedPromise<any>
	if not isLargeFile(file) then
		return Promise.resolve(file.data)
	end

	local shardId = file.shard
	local promises = {}

	for i = 1, file.count do
		table.insert(promises, self._dataStoreInterface:get(Constants.SHARD_SCOPE, `{shardId}-{i}`))
	end

	return Promise.all(promises):andThen(function(shards)
		return HttpService:JSONDecode(table.concat(shards))
	end)
end
Store._readLargeFile = wrapPromiseFunc(Store._readLargeFile, t.tuple(t.any, Types.fileCheck), t.tuple(t.any))

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
Store._readTx = wrapPromiseFunc(Store._readTx, t.tuple(t.any, Types.txInfoCheck), t.tuple(t.any))

function Store:_enqueueKeyOperation(key: string, operation: () -> Promise.Promise): Promise.Promise
	local queue = self._keyInfo[key].operationQueue

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
Store._enqueueKeyOperation =
	wrapPromiseFunc(Store._enqueueKeyOperation, t.tuple(t.any, t.string, t.callback), t.tuple(t.none))

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

	return Promise.all(promises):andThenReturn(promise)
end
Store._enqueueMultiKeyOperation =
	wrapPromiseFunc(Store._enqueueMultiKeyOperation, t.tuple(t.any, t.array(t.string), t.callback), t.tuple(t.none))

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
	return Sift.Set.copy(self._keyInfo[key].unsavedMutations)
end
Store._getSnapshot = t.wrap(Store._getSnapshot, t.tuple(t.any, t.string))

function Store:_isSnapshotCommitted(snapshot: UnsavedMutationsSnapshot, key: string): boolean
	local intersection = Sift.Set.intersection(snapshot, self._keyInfo[key].unsavedMutations)
	return Sift.Set.count(intersection) == 0
end
Store._isSnapshotCommitted = t.wrap(Store._isSnapshotCommitted, t.tuple(t.any, unsavedMutationsSnapshotCheck, t.string))

function Store:_commitSnapshot(snapshot: UnsavedMutationsSnapshot, key: string): ()
	self._keyInfo[key].unsavedMutations = Sift.Set.difference(self._keyInfo[key].unsavedMutations, snapshot)
end
Store._commitSnapshot = t.wrap(Store._commitSnapshot, t.tuple(t.any, unsavedMutationsSnapshotCheck, t.string))

function Store:_isSaved(key: string): boolean
	return Sift.Set.count(self._keyInfo[key].unsavedMutations) == 0
end
Store._isSaved = t.wrap(Store._isSaved, t.tuple(t.any, t.string))

function Store:lock(key: string, userIds: { number }?): Promise.Promise
	local function transformFunction(value, _previousUserIds, previousMetadata)
		value = Sift.Dictionary.mergeDeep({ lock = {} }, value)

		local lock = value.lock
		if lock.expiry ~= nil and lock.expiry > DateTime.now().UnixTimestamp then
			-- TODO: retry after lock expiry
			return nil
		end

		value.lock = self:_getLock()

		return value, userIds, previousMetadata
	end

	local keyInfo = {
		data = nil,
		metadata = nil,
		unsavedMutations = {},
		operationQueue = {},
		orphanedShards = {},
		stagedShards = {},
	}

	return self._dataStoreInterface
		:update(Constants.RECORD_SCOPE, key, transformFunction)
		:andThen(function(record, _userIds, metadata)
			if record.lock.id ~= self._lockId then
				return Promise.reject("Failed to acquire lock")
			end

			keyInfo.metadata = metadata

			if record.orphanedShards then
				keyInfo.orphanedShards = record.orphanedShards
				for _, shard in record.orphanedShards do
					self:_markOrphanedShards(shard)
				end
			end

			local file = record.file
			return if file then self:_readLargeFile(file) else nil :: any
		end)
		:andThen(function(txInfo)
			return if txInfo then self:_readTx(txInfo) else nil
		end)
		:andThen(function(data)
			if data == nil then
				data = Sift.Dictionary.copyDeep(self._template)
			end

			-- TODO: migrations

			keyInfo.data = data
			self._keyInfo[key] = keyInfo

			return data
		end)
	-- TODO: Add catch handler to mark orphaned shards
end
Store.lock = wrapPromiseFunc(Store.lock, t.tuple(t.any, t.string, t.optional(t.array(t.number))), t.tuple(t.any))

function Store:unlock(key: string, userIds: { number }?): Promise.Promise
	-- TODO: forbid any other mutations to the key from here on out
	return self:_enqueueKeyOperation(key, function()
		local keyInfo = self._keyInfo[key]
		local data = Sift.Dictionary.copyDeep(keyInfo.data)
		local txInfo = { committedData = data }

		return self:_writeLargeFile(key, txInfo, userIds)
			:andThen(function(file)
				local orphanedShards = Sift.Array.join(keyInfo.orphanedShards, keyInfo.stagedShards)
				local record = {
					lock = {
						id = nil,
						expiry = nil,
					},
					file = file,
					orphanedShards = orphanedShards,
				}
				local metadata = keyInfo.metadata[key]

				local function transformFunction(value, previousUserIds, previousMetadata)
					if value.lock.id ~= self._lockId then
						return nil :: any, previousUserIds, previousMetadata
					end
					return record, userIds, metadata
				end

				return self._dataStoreInterface
					:update(Constants.RECORD_SCOPE, key, transformFunction)
					:andThen(function()
						keyInfo.orphanedShards = orphanedShards
						if isLargeFile(file) then
							keyInfo.stagedShards = { file }
						else
							keyInfo.stagedShards = {}
						end
					end)
					:catch(function(err)
						if isLargeFile(file) then
							self:_markOrphanedShards(file)
							keyInfo.orphanedShards = Sift.Array.push(keyInfo.orphanedShards, file)
						end
						return Promise.reject(err)
					end)
			end)
			:andThen(function(latestValue)
				if latestValue.lock.id ~= nil then
					return Promise.reject("Failed to release lock")
				end

				self:_markOrphanedShards(table.unpack(latestValue.orphanedShards))
				keyInfo[key] = nil

				return nil :: any
			end)
		-- TODO: Add catch handler to mark orphaned shards
	end)
end
Store.unlock = wrapPromiseFunc(Store.unlock, t.tuple(t.any, t.string, t.optional(t.array(t.number))), t.tuple(t.none))

function Store:_mutateKey(key: string, newData: any): ()
	local mutationId = HttpService:GenerateGUID(false)
	local keyInfo = self._keyInfo[key]
	keyInfo.unsavedMutations = Sift.Set.add(keyInfo.unsavedMutations, mutationId)
	keyInfo.data = newData
end
Store._mutateKey = t.wrap(Store._mutateKey, t.tuple(t.any, t.string, t.any))

function Store:update(key: string, transformFunction: (data: any) -> any): Promise.Promise
	return Promise.new(function(resolve, reject)
		while self._txLockPromises[key] ~= nil do
			self._txLockPromises[key]:await()
		end

		local currentData = self._keyInfo[key].data
		local nextData = Sift.Dictionary.copyDeep(currentData)
		local transformOk, result = pcall(noYield, transformFunction, nextData)
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
Store.update = wrapPromiseFunc(Store.update, t.tuple(t.any, t.string, t.callback), t.tuple(t.none))

function Store:tx(
	keys: { string },
	transformFunction: (state: { [string]: any }) -> { [string]: any }?,
	userIds: { number }?
): Promise.Promise
	local txLockResolve
	local txLockPromise = Promise.new(function(_resolve)
		txLockResolve = _resolve
	end)

	return self:_enqueueMultiKeyOperation(keys, function()
		local currentState = {}
		for _, key in keys do
			self._txLockPromises[key] = txLockPromise
			currentState[key] = self._keyInfo[key].data
		end

		local nextState = Sift.Dictionary.copyDeep(currentState)
		local transformOk, result = pcall(noYield, transformFunction, nextState)
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

		local promises = Sift.Array.map(keys, function(key, index)
			local txInfo = {
				txId = txId,
				committedData = currentState[key],
				txData = nextState[key],
			}

			local keyUserId = if userIds then { userIds[index] } else nil

			return self:_writeLargeFile(key, txInfo, keyUserId):andThen(function(file)
				local keyInfo = self._keyInfo[key]
				local orphanedShards = Sift.Array.join(keyInfo.orphanedShards, keyInfo.stagedShards)

				local record = {
					lock = self:_getLock(),
					file = file,
					orphanedShards = orphanedShards,
				}
				local metadata = keyInfo.metadata

				return self._dataStoreInterface
					:update(Constants.RECORD_SCOPE, key, function(previousValue, previousUserIds, previousMetadata)
						if previousValue.lock.id ~= self._lockId then
							return nil :: any, previousUserIds, previousMetadata
						end

						return record, keyUserId, metadata
					end, keyUserId)
					:andThen(function()
						-- TODO: verify lock

						self:_markOrphanedShards(table.unpack(keyInfo.stagedShards))

						keyInfo.orphanedShards = orphanedShards

						if isLargeFile(file) then
							keyInfo.stagedShards = { file }
						else
							keyInfo.stagedShards = {}
						end
					end)
					:catch(function(err)
						if isLargeFile(file) then
							self:_markOrphanedShards(file)
							keyInfo.orphanedShards = Sift.Array.push(keyInfo.orphanedShards, file)
						end

						return Promise.reject(err)
					end)
			end)
		end)

		local commitPromise = Promise.all(promises)
			:andThen(function()
				return self._dataStoreInterface:set(Constants.TX_SCOPE, txId, true)
			end)
			:andThen(function()
				for _, key in keys do
					-- :tx is required to save, so we commit all unsaved
					-- mutations here
					local snapshot = self:_getSnapshot(key)
					self:_commitSnapshot(snapshot, key)
					self._keyInfo[key].data = nextState[key]
				end
			end)
			:catch(function(err)
				self._dataStoreInterface:set(Constants.TX_SCOPE, txId, false):catch(function(_arbortErr)
					-- TODO: log this
				end)

				return Promise.reject(err)
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
Store.tx = wrapPromiseFunc(
	Store.tx,
	t.tuple(t.any, t.array(t.string), t.callback, t.optional(t.array(t.number))),
	t.tuple(t.none)
)

function Store:save(key: string, userIds: { number }?): Promise.Promise
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

		local keyInfo = self._keyInfo[key]
		local data = Sift.Dictionary.copyDeep(keyInfo.data)
		local txInfo = { committedData = data }

		return self:_writeLargeFile(key, txInfo, userIds)
			:andThen(function(file)
				local orphanedShards = Sift.Array.join(keyInfo.orphanedShards, keyInfo.stagedShards)
				local record = {
					lock = self:_getLock(),
					file = file,
					orphanedShards = orphanedShards,
				}
				local metadata = keyInfo.metadata

				return self._dataStoreInterface
					:set(Constants.RECORD_SCOPE, key, record, userIds, metadata)
					:andThen(function()
						keyInfo.orphanedShards = orphanedShards
						if isLargeFile(file) then
							keyInfo.stagedShards = { file }
						else
							keyInfo.stagedShards = {}
						end
					end)
					:catch(function(err)
						if isLargeFile(file) then
							self:_markOrphanedShards(file)
							keyInfo.orphanedShards = Sift.Array.push(keyInfo.orphanedShards, file)
						end
						return Promise.reject(err)
					end)
			end)
			:andThen(function()
				self:_commitSnapshot(snapshot, key)
			end)
	end)
end
Store.save = wrapPromiseFunc(Store.save, t.tuple(t.any, t.string, t.optional(t.array(t.number))), t.tuple(t.none))

return {
	createStore = createStore,
}
