--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(script.Parent.Constants)
local PromiseQueue = require(script.Parent.PromiseQueue)
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
		_lastTxId = nil,
		_fileCleanupQueue = {},
	}, { __index = Store })

	local ok, err = self._schema(self._template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	return self
end
createStore = t.wrap(createStore, t.tuple(storeConfigCheck))

function Store:_cleanupOrphanedFiles()
	while #self._fileCleanupQueue > 0 do
		local minBudget = 100
		local curBudget =
			self._dataStoreInterface:getRequestBudgetForBudgetType(Enum.DataStoreRequestType.SetIncrementAsync)
		if curBudget < minBudget then
			task.wait(0.1)
			continue
		end

		local entry
		for _, otherEntry: any in self._fileCleanupQueue do
			if otherEntry.beingProcessed then
				continue
			end
			entry = otherEntry
			break
		end

		if entry == nil then
			task.wait(0.1)
			continue
		end

		entry.beingProcessed = true

		local promises = {}
		for i = 1, #entry.file.count do
			table.insert(promises, self._dataStoreInterface:delete(Constants.SHARD_SCOPE, `{entry.file.shard}-{i}`))
		end

		Promise.all(promises)
			:andThen(function()
				self._fileCleanupQueue = Sift.Array.removeValue(self._fileCleanupQueue, entry)

				local keyInfo = self._keyInfo[entry.key]
				keyInfo.orphanedFiles = Sift.Array.filter(keyInfo.orphanedFiles, function(file)
					return not Sift.Dictionary.equals(file, entry.file)
				end)
			end)
			:finally(function()
				entry.beingProcessed = false
			end)

		task.wait(0.1)
	end
end

function Store:_markOrphanedFile(key: string, file: Types.File): ()
	if not isLargeFile(file) then
		return
	end

	local isMarked = Sift.Array.findWhere(self._fileCleanupQueue, function(entry)
		return Sift.Dictionary.equals(entry.file, file)
	end)

	if isMarked then
		return
	end

	table.insert(self._fileCleanupQueue, { key = key, file = file, beingProcessed = false })

	if #self._fileCleanupQueue == 1 then
		task.spawn(function()
			self:_cleanupOrphanedFiles()
		end)
	end
end
Store._markOrphanedFile = t.wrap(Store._markOrphanedFile, t.tuple(t.any, t.string, Types.fileCheck))

function Store:_markOrphanedFiles(key: string, files: { Types.File }): ()
	for _, file in files do
		self:_markOrphanedFile(key, file)
	end
end
Store._markOrphanedFiles = t.wrap(Store._markOrphanedFiles, t.tuple(t.any, t.string, t.array(Types.fileCheck)))

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
		table.insert(self._keyInfo[key].orphanedFiles, file)
		self:_markOrphanedFile(key, file)
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

	return self._dataStoreInterface:get(Constants.TX_SCOPE, txId):andThen(function(committed)
		if committed == true then
			return txInfo.txData
		else
			return txInfo.committedData
		end
	end)
end
Store._readTx = wrapPromiseFunc(Store._readTx, t.tuple(t.any, Types.txInfoCheck), t.tuple(t.any))

function Store:_writeRecord(
	key: string,
	txInfo: Types.TxInfo,
	userIds: { number }?,
	releaseLock: boolean?
): Promise.TypedPromise<any>
	return self:_writeLargeFile(key, txInfo, userIds):andThen(function(file)
		local keyInfo = self._keyInfo[key]
		local orphanedFiles = Sift.Array.push(keyInfo.orphanedFiles, keyInfo.currentFile)

		local record = {
			lock = if releaseLock then {} else self:_getLock(),
			file = file,
			orphanedFiles = orphanedFiles,
		}
		local metadata = keyInfo.metadata

		return self._dataStoreInterface
			:update(Constants.RECORD_SCOPE, key, function(previousValue, previousUserIds, previousMetadata)
				if previousValue.lock.id ~= self._lockId then
					return nil :: any, previousUserIds, previousMetadata
				end

				return record, userIds, metadata
			end, userIds)
			:andThen(function(value)
				if releaseLock and value.lock.id ~= nil then
					return Promise.reject("Failed to release lock")
				elseif not releaseLock and value.lock.id ~= self._lockId then
					return Promise.reject("Lock violation")
				end

				keyInfo.orphanedFiles = orphanedFiles
				keyInfo.currentFile = if isLargeFile(file) then file else nil
				if keyInfo.currentFile then
					self:_markOrphanedFile(key, keyInfo.currentFile)
				end

				return value
			end)
			:catch(function(err)
				if isLargeFile(file) then
					keyInfo.orphanedFiles = Sift.Array.push(keyInfo.orphanedFiles, file)
					self:_markOrphanedFile(key, file)
				end

				return Promise.reject(err)
			end)
	end)
end
Store._writeRecord = wrapPromiseFunc(
	Store._writeRecord,
	t.tuple(t.any, t.string, Types.txInfoCheck, t.optional(t.array(t.number)), t.optional(t.boolean)),
	t.tuple(t.any)
)

function Store:_getLock(): Types.Lock
	return {
		id = self._lockId,
		expiry = DateTime.now().UnixTimestamp + Constants.LOCK_DURATION_SECONDS,
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

function Store:_mutateKey(key: string, newData: any): ()
	local mutationId = HttpService:GenerateGUID(false)
	local keyInfo = self._keyInfo[key]
	keyInfo.unsavedMutations = Sift.Set.add(keyInfo.unsavedMutations, mutationId)
	keyInfo.data = newData
end
Store._mutateKey = t.wrap(Store._mutateKey, t.tuple(t.any, t.string, t.any))

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
		orphanedFiles = {},
		currentFile = nil :: any,
		queue = PromiseQueue.new(),
		txLockPromise = nil,
	}

	return self._dataStoreInterface
		:update(Constants.RECORD_SCOPE, key, transformFunction)
		:andThen(function(record, _userIds, metadata)
			if record.lock.id ~= self._lockId then
				return Promise.reject("Failed to acquire lock")
			end

			keyInfo.metadata = metadata

			if record.orphanedFiles then
				keyInfo.orphanedFiles = record.orphanedFiles
				self:_markOrphanedFiles(key, record.orphanedFiles)
			end

			local file = record.file
			if file then
				if isLargeFile(file) then
					keyInfo.currentFile = file
				end

				return self:_readLargeFile(file)
			end

			return nil :: any
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
end
Store.lock = wrapPromiseFunc(Store.lock, t.tuple(t.any, t.string, t.optional(t.array(t.number))), t.tuple(t.any))

function Store:unlock(key: string, userIds: { number }?): Promise.Promise
	-- TODO: forbid any other mutations to the key from here on out
	-- TODO: error when queue is added to from here on out
	local keyInfo = self._keyInfo[key]
	return keyInfo.queue:add(function()
		local data = Sift.Dictionary.copyDeep(keyInfo.data)
		local txInfo = { committedData = data }

		return self:_writeRecord(key, txInfo, userIds, true):andThen(function(latestValue)
			self:_markOrphanedFiles(key, latestValue.orphanedFiles)
			self._keyInfo[key] = nil
		end)
	end)
end
Store.unlock = wrapPromiseFunc(Store.unlock, t.tuple(t.any, t.string, t.optional(t.array(t.number))), t.tuple(t.none))

function Store:update(key: string, transformFunction: (data: any) -> any): Promise.Promise
	local keyInfo = self._keyInfo[key]

	return Promise.new(function(resolve, reject)
		while keyInfo.txLockPromise ~= nil do
			keyInfo.txLockPromise:await()
		end

		local currentData = self._keyInfo[key].data
		local nextData = Sift.Dictionary.copyDeep(currentData)
		local transformOk, result = pcall(noYield, transformFunction, nextData)
		if not transformOk then
			return reject(`Store:update transformFunction failed: {result}`)
		end

		if result == nil then
			print(`Skipping update for key {key}`)
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
	userIds: { { number } }?
): Promise.Promise
	local txLockResolve
	local txLockPromise = Promise.new(function(resolve)
		txLockResolve = resolve
	end)

	local queues = Sift.Array.map(keys, function(key)
		return self._keyInfo[key].queue
	end)

	return PromiseQueue.multiQueueAdd(queues, function()
		local currentState = {}
		for _, key in keys do
			local keyInfo = self._keyInfo[key]

			keyInfo.txLockPromise = txLockPromise
			currentState[key] = keyInfo.data

			-- TODO: verify we have lock on all keys
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

		self._lastTxId = HttpService:GenerateGUID(false)
		local txId = self._lastTxId

		local promises = Sift.Array.map(keys, function(key, index)
			local txInfo = {
				txId = txId,
				committedData = currentState[key],
				txData = nextState[key],
			}

			local keyUserIds = if userIds then userIds[index] else nil

			return self:_writeRecord(key, txInfo, keyUserIds)
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
			local keyInfo = self._keyInfo[key]
			if keyInfo.txLockPromise == txLockPromise then
				keyInfo.txLockPromise = nil :: any
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
	local keyInfo = self._keyInfo[key]

	return keyInfo.queue:add(function()
		if self:_isSnapshotCommitted(snapshot, key) then
			return
		end

		if self:_isSaved(key) then
			return
		end

		snapshot = self:_getSnapshot(key)

		local data = Sift.Dictionary.copyDeep(keyInfo.data)
		local txInfo = { committedData = data }

		return self:_writeRecord(key, txInfo, userIds):andThen(function()
			self:_commitSnapshot(snapshot, key)
		end)
	end)
end
Store.save = wrapPromiseFunc(Store.save, t.tuple(t.any, t.string, t.optional(t.array(t.number))), t.tuple(t.none))

return {
	createStore = createStore,
}
