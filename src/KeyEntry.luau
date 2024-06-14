--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(script.Parent.Constants)
local Log = require(script.Parent.Log)
local PromiseQueue = require(script.Parent.PromiseQueue)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local t = require(ReplicatedStorage.Packages.t)
local Types = require(script.Parent.Types)
local getBackoffTime = require(script.Parent.getBackoffTime)
local noYield = require(script.Parent.noYield)
local splitUtf8String = require(script.Parent.splitUtf8String)

local Dictionary = Sift.Dictionary
local Array = Sift.Array
local Set = Sift.Set

type UnsavedMutationsSnapshot = { [string]: boolean }
local unsavedMutationsSnapshotCheck = t.map(t.string, t.boolean)

local function isLargeFile(file: Types.File): boolean
	return file.shard ~= nil
end

type UpdateRecordParams = {
	txInfo: Types.TxInfo?,
	releaseLock: boolean?,
}
local updateRecordParamsCheck = t.strictInterface({
	txInfo = t.optional(Types.txInfoCheck),
	releaseLock = t.boolean,
})

type KeyEntryImpl<T> = {
	__index: KeyEntryImpl<T>,

	new: (config: KeyEntryConfig<T>) -> KeyEntry<T>,

	-- TODO: Update data: any to a more specific type
	writeLargeFile: (
		self: KeyEntry<T>,
		data: any,
		metadata: { [string]: any }?
	) -> Promise.TypedPromise<Types.File>,
	readLargeFile: (self: KeyEntry<T>, file: Types.File) -> Promise.TypedPromise<any>,
	readTx: (self: KeyEntry<T>, txInfo: Types.TxInfo) -> Promise.TypedPromise<any>,
	updateRecord: (self: KeyEntry<T>, params: UpdateRecordParams) -> Promise.TypedPromise<any>,

	getLock: (self: KeyEntry<T>) -> Types.Lock,

	getSnapshot: (self: KeyEntry<T>) -> UnsavedMutationsSnapshot,
	isSnapshotCommitted: (self: KeyEntry<T>, snapshot: UnsavedMutationsSnapshot) -> boolean,
	commitSnapshot: (self: KeyEntry<T>, snapshot: UnsavedMutationsSnapshot) -> (),
	isSaved: (self: KeyEntry<T>) -> boolean,

	mutateKey: (self: KeyEntry<T>, newData: T) -> (),
	migrateData: (self: KeyEntry<T>, data: any) -> Promise.TypedPromise<any>,

	waitUntilLocked: (self: KeyEntry<T>) -> Promise.Promise,
	startAutosaving: (self: KeyEntry<T>) -> (),

	lock: (self: KeyEntry<T>) -> Promise.Promise,
	unlock: (self: KeyEntry<T>) -> Promise.Promise,
	get: (self: KeyEntry<T>) -> Promise.TypedPromise<T>,
	update: (self: KeyEntry<T>, transformFunction: (data: T) -> T?) -> Promise.Promise,
	save: (self: KeyEntry<T>) -> Promise.Promise,
}

type KeyEntryProps<T> = {
	key: string,
	ctx: Types.StoreContext<T>,

	userIds: { number }?,
	metadata: { [string]: any }?,

	data: T?,
	version: number,

	unsavedMutations: UnsavedMutationsSnapshot,

	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	queue: PromiseQueue.PromiseQueue,
	txLockPromise: Promise.Promise?,

	closed: boolean,
	locked: boolean,
	acquireLockPromise: Promise.Promise?,
	refreshLock: boolean,

	recordScope: string,
	shardScope: string,
	txScope: string,
}

export type KeyEntry<T> = typeof(setmetatable({} :: KeyEntryProps<T>, {} :: KeyEntryImpl<T>))

type KeyEntryConfig<T> = {
	key: string,
	storeContext: Types.StoreContext<T>,
	userIds: { number }?,
}
local keyEntryConfigCheck = t.strictInterface({
	key = t.string,
	storeContext = t.any,
	userIds = t.optional(t.array(t.number)),
})

local KeyEntry: KeyEntryImpl<any> = {} :: KeyEntryImpl<any>
KeyEntry.__index = KeyEntry

function KeyEntry.new<T>(config: KeyEntryConfig<T>): KeyEntry<T>
	Log.trace(`Creating new KeyEntry for key {config.key}`)
	return setmetatable({
		key = config.key,
		ctx = config.storeContext,

		userIds = config.userIds,
		metadata = nil,

		data = nil,
		version = config.storeContext.latestVersion,

		unsavedMutations = {},

		orphanedFiles = {},
		currentFile = nil,
		queue = PromiseQueue.new(),
		txLockPromise = nil,

		closed = false,
		locked = false,
		acquireLockPromise = nil,
		refreshLock = false,

		recordScope = `{Constants.RECORD_SCOPE}/{config.storeContext.name}`,
		shardScope = `{Constants.SHARD_SCOPE}/{config.storeContext.name}`,
		txScope = `{Constants.TX_SCOPE}/{config.storeContext.name}`,
	}, KeyEntry) :: KeyEntry<T>
end
KeyEntry.new = t.wrap(KeyEntry.new, t.tuple(keyEntryConfigCheck))

-- TODO: Update data: any to a more specific type
function KeyEntry:writeLargeFile(data: any, metadata: { [string]: any }?): Promise.TypedPromise<Types.File>
	Log.trace(`KeyEntry:writeLargeFile called for key {self.key}`)
	local str = HttpService:JSONEncode(data)
	if #str <= Constants.MAX_CHUNK_SIZE then
		Log.trace(`KeyEntry:writeLargeFile - Data for key {self.key} is small, not sharding`)
		return Promise.resolve({ data = data } :: Types.File)
	end

	local shardId = HttpService:GenerateGUID(false)
	Log.debug(`KeyEntry:writeLargeFile - Data for key {self.key} is large, sharding with ID {shardId}`)

	-- TODO: Add a test case ensuring that splitUtf8String is called with the correct arguments
	local shards = splitUtf8String(str, Constants.MAX_CHUNK_SIZE)
	Log.debug(`KeyEntry:writeLargeFile - Split data for key {self.key} into {#shards} shards`)

	local promises = Array.map(shards, function(shard, index)
		Log.trace(`KeyEntry:writeLargeFile - Writing shard {index} for key {self.key}`)
		return self.ctx.dataStoreInterface:set(self.shardScope, `{shardId}-{index}`, shard, self.userIds, metadata)
	end)

	local file = { shard = shardId, count = #shards }

	local p = Promise.all(promises):andThenReturn(file):catch(function(err)
		Log.error(`KeyEntry:writeLargeFile - Failed to write shards for key {self.key}: {err}`)
		table.insert(self.orphanedFiles, file)
		self.ctx.orphanedFileQueue:markFile(self.key, file)
		return Promise.reject(err)
	end)

	return p
end
-- TODO: Update data: any to a more specific type
KeyEntry.writeLargeFile = t.wrap(KeyEntry.writeLargeFile, t.tuple(t.any, t.any, t.optional(t.map(t.string, t.any))))

function KeyEntry:readLargeFile(file: Types.File): Promise.TypedPromise<any>
	Log.trace(`KeyEntry:readLargeFile called for key {self.key}`)
	if not isLargeFile(file) then
		Log.trace(`KeyEntry:readLargeFile - File for key {self.key} is not sharded`)
		return Promise.resolve(file.data)
	end

	local shardId = file.shard
	Log.debug(`KeyEntry:readLargeFile - Reading sharded file for key {self.key} with ID {shardId}`)

	local promises = {}

	for i = 1, file.count do
		Log.trace(`KeyEntry:readLargeFile - Reading shard {i} for key {self.key}`)
		table.insert(promises, self.ctx.dataStoreInterface:get(self.shardScope, `{shardId}-{i}`))
	end

	return Promise.all(promises):andThen(function(shards)
		Log.trace(`KeyEntry:readLargeFile - Assembling {file.count} shards for key {self.key}`)
		return HttpService:JSONDecode(table.concat(shards))
	end)
end
KeyEntry.readLargeFile = t.wrap(KeyEntry.readLargeFile, t.tuple(t.any, Types.fileCheck))

function KeyEntry:readTx(txInfo: Types.TxInfo): Promise.TypedPromise<any>
	Log.trace(`KeyEntry:readTx called for key {self.key}`)
	local txId = txInfo.txId
	if txId == nil then
		Log.trace(`KeyEntry:readTx - No txId for key {self.key}, returning committedData`)
		return Promise.resolve(txInfo.committedData)
	end

	Log.debug(`KeyEntry:readTx - Reading transaction data for key {self.key} with ID {txId}`)
	return self.ctx.dataStoreInterface:get(self.txScope, txId):andThen(function(committed)
		if committed == true then
			Log.trace(`KeyEntry:readTx - Transaction {txId} for key {self.key} is committed, returning txData`)
			return txInfo.txData
		else
			Log.trace(
				`KeyEntry:readTx - Transaction {txId} for key {self.key} is not committed, returning committedData`
			)
			return txInfo.committedData
		end
	end)
end
KeyEntry.readTx = t.wrap(KeyEntry.readTx, t.tuple(t.any, Types.txInfoCheck))

-- This method is complex and does multiple things.
-- It is responsible for writing the DataStoreRecord. It does different things
-- depending on the parameters passed to it.
--
-- * If `params.releaseLock` is true, it releases the lock and verifies that it
--   was released.
--
-- * If `params.txInfo` is provided, it will write it and handles it correctly
--   in the case it's a large file.
--
-- * If `params.txInfo` is not provided, then:
--   * If the key is not saved: It will write the latest data and handle the
--     large file case correctly.
--   * If the key is saved: It will attempt to reuse the current file if it's a
--     large file, in order to avoid writing it again unnecessarily.
function KeyEntry:updateRecord(params: UpdateRecordParams): Promise.TypedPromise<any>
	Log.trace(`KeyEntry:updateRecord called for key {self.key}`)
	local releaseLock = params.releaseLock
	local txInfo = params.txInfo

	local function writeRecord(record: Types.DataStoreRecord)
		local metadata = self.metadata

		return self.ctx.dataStoreInterface
			:update(self.recordScope, self.key, function(previousValue, keyInfo)
				if previousValue.lock.id ~= self.ctx.lockId then
					Log.warn(`KeyEntry:updateRecord - Lock violation detected for key {self.key}, aborting update`)
					return nil :: any, keyInfo:GetUserIds(), keyInfo:GetMetadata()
				end

				Log.trace(`KeyEntry:updateRecord - Successfully validated lock for key {self.key}`)
				return record, self.userIds, metadata
			end)
			:andThen(function(value)
				if releaseLock and (value == nil or value.lock.id ~= nil) then
					Log.error(`KeyEntry:updateRecord - Failed to release lock for key {self.key}`)
					return Promise.reject("Failed to release lock")
				elseif not releaseLock and (value == nil or value.lock.id ~= self.ctx.lockId) then
					Log.error(`KeyEntry:updateRecord - Lock violation detected for key {self.key}`)
					return Promise.reject("Lock violation")
				end

				self.refreshLock = false

				return value
			end)
	end

	local needsUpdate = not self:isSaved()
	if needsUpdate or txInfo ~= nil then
		if txInfo == nil then
			txInfo = { committedData = Dictionary.copyDeep(self.data) }
		end

		return self:writeLargeFile(txInfo):andThen(function(file)
			local orphanedFiles = Array.push(self.orphanedFiles, self.currentFile :: any)

			local record = {
				version = self.version,
				lock = if releaseLock then {} else self:getLock(),
				file = file,
				orphanedFiles = orphanedFiles,
			}

			return writeRecord(record)
				:andThen(function(value)
					Log.debug(`KeyEntry:updateRecord - Successfully updated record for key {self.key}`)
					self.orphanedFiles = orphanedFiles
					self.currentFile = if isLargeFile(file) then file else nil
					if self.currentFile then
						self.ctx.orphanedFileQueue:markFile(self.key, self.currentFile)
					end

					return value
				end)
				:catch(function(err)
					Log.error(`KeyEntry:updateRecord - Failed to update record for key {self.key}: {err}`)
					if isLargeFile(file) then
						self.orphanedFiles = Array.push(self.orphanedFiles, file)
						self.ctx.orphanedFileQueue:markFile(self.key, file)
					end

					return Promise.reject(err)
				end)
		end)
	else
		local file = if self.currentFile then self.currentFile else { data = self.data } :: any
		return writeRecord({
			version = self.version,
			lock = if releaseLock then {} else self:getLock(),
			file = file,
			orphanedFiles = self.orphanedFiles,
		})
	end
end
KeyEntry.updateRecord = t.wrap(KeyEntry.updateRecord, t.tuple(t.any, updateRecordParamsCheck))

function KeyEntry:getLock(): Types.Lock
	Log.trace(`KeyEntry:getLock called for key {self.key}`)
	return {
		id = self.ctx.lockId,
		expiry = DateTime.now().UnixTimestamp + Constants.LOCK_DURATION_SECONDS,
	}
end

function KeyEntry:getSnapshot(): UnsavedMutationsSnapshot
	Log.trace(`KeyEntry:getSnapshot called for key {self.key}`)
	return Set.copy(self.unsavedMutations)
end
KeyEntry.getSnapshot = t.wrap(KeyEntry.getSnapshot, t.tuple(t.any))

function KeyEntry:isSnapshotCommitted(snapshot: UnsavedMutationsSnapshot): boolean
	Log.trace(`KeyEntry:isSnapshotCommitted called for key {self.key}`)
	local intersection = Set.intersection(snapshot, self.unsavedMutations)
	return Set.count(intersection) == 0
end
KeyEntry.isSnapshotCommitted = t.wrap(KeyEntry.isSnapshotCommitted, t.tuple(t.any, unsavedMutationsSnapshotCheck))

function KeyEntry:commitSnapshot(snapshot: UnsavedMutationsSnapshot): ()
	Log.trace(`KeyEntry:commitSnapshot called for key {self.key}`)
	self.unsavedMutations = Set.difference(self.unsavedMutations, snapshot)
end
KeyEntry.commitSnapshot = t.wrap(KeyEntry.commitSnapshot, t.tuple(t.any, unsavedMutationsSnapshotCheck))

function KeyEntry:isSaved(): boolean
	Log.trace(`KeyEntry:isSaved called for key {self.key}`)
	return Set.count(self.unsavedMutations) == 0
end
KeyEntry.isSaved = t.wrap(KeyEntry.isSaved, t.tuple(t.any))

function KeyEntry:mutateKey(newData: any): ()
	Log.trace(`KeyEntry:mutateKey called for key {self.key}`)
	local oldData = if self.data then Dictionary.freezeDeep(self.data :: any) else nil

	local mutationId = HttpService:GenerateGUID(false)
	self.unsavedMutations = Set.add(self.unsavedMutations, mutationId)
	self.data = newData

	newData = Dictionary.freezeDeep(newData :: any)
	Log.debug(`KeyEntry:mutateKey - Mutated key {self.key} with new data`, newData)

	for _, callback in self.ctx.changedCallbacks do
		task.spawn(callback, self.key, newData, oldData)
	end
end
KeyEntry.mutateKey = t.wrap(KeyEntry.mutateKey, t.tuple(t.any, t.any))

function KeyEntry:migrateData(data: any): Promise.TypedPromise<any>
	Log.trace(`KeyEntry:migrateData called for key {self.key}`)
	data = Dictionary.copyDeep(data)
	return Promise.new(function(resolve)
		for i = self.version + 1, self.ctx.latestVersion do
			Log.trace(`KeyEntry:migrateData - Migrating key {self.key} from version {i - 1} to {i}`)
			local migration = self.ctx.migrations[i]
			if migration then
				local newData = Promise.try(migration, data):expect()
				data = Dictionary.copyDeep(newData)
			end
		end
		Log.debug(`KeyEntry:migrateData - Migrated key {self.key} to version {self.ctx.latestVersion}`)

		resolve(data)
	end)
end

function KeyEntry:waitUntilLocked(): Promise.Promise
	Log.trace(`KeyEntry:waitUntilLocked called for key {self.key}`)
	return Promise.resolve(self.acquireLockPromise):andThen(function()
		if not self.locked then
			Log.error(`KeyEntry:waitUntilLocked - KeyEntry for key {self.key} is not locked`)
			return Promise.reject("KeyEntry is not locked")
		end
		if self.closed then
			Log.error(`KeyEntry:waitUntilLocked - KeyEntry for key {self.key} is closed`)
			return Promise.reject("KeyEntry is closed")
		end
	end)
end

function KeyEntry:startAutosaving(): ()
	Log.info(`KeyEntry:startAutosaving - Starting autosave for key {self.key}`)
	task.spawn(function()
		while true do
			task.wait(Constants.AUTOSAVE_INTERVAL_SECONDS)
			if self.closed then
				Log.info(`KeyEntry:startAutosaving - Autosave loop for key {self.key} exiting, KeyEntry is closed`)
				break
			end

			Log.trace(`KeyEntry:startAutosaving - Autosaving key {self.key}`)
			self.refreshLock = true
			local ok, err = self:save():await()
			if not ok then
				Log.warn(`KeyEntry:startAutosaving - Failed to autosave key {self.key}: {err}`)
			end
		end
	end)
end

function KeyEntry:lock(): Promise.Promise
	Log.trace(`KeyEntry:lock called for key {self.key}`)
	if self.locked then
		Log.warn(`KeyEntry:lock - KeyEntry for key {self.key} is already locked`)
		return Promise.reject("KeyEntry is already locked")
	end
	if self.closed then
		Log.warn(`KeyEntry:lock - KeyEntry for key {self.key} is closed`)
		return Promise.reject("KeyEntry is closed")
	end
	if self.acquireLockPromise then
		Log.trace(`KeyEntry:lock - KeyEntry for key {self.key} is already being locked`)
		return Promise.reject("KeyEntry is already being locked")
	end

	local function transformFunction(value, keyInfo)
		value = Dictionary.mergeDeep({ lock = {} }, value)

		local previousUserIds = keyInfo and keyInfo:GetUserIds()
		local previousMetadata = keyInfo and keyInfo:GetMetadata()

		local lock = value.lock
		if lock.expiry ~= nil and lock.expiry > DateTime.now().UnixTimestamp then
			Log.trace(`KeyEntry:lock - Lock for key {self.key} is still valid, aborting lock acquisition`)
			return nil, previousUserIds, previousMetadata
		end

		Log.trace(`KeyEntry:lock - Acquiring lock for key {self.key}`)
		value.lock = self:getLock()

		return value, self.userIds, previousMetadata
	end

	local function tryAcquireLock(): (Types.DataStoreRecord, DataStoreKeyInfo)
		for i = 1, Constants.LOCK_ACQUIRE_ATTEMPTS do
			Log.trace(
				`KeyEntry:lock - Attempting to acquire lock for key {self.key}, attempt {i}/{Constants.LOCK_ACQUIRE_ATTEMPTS}`
			)
			local resolved, record, keyInfo =
				self.ctx.dataStoreInterface:update(self.recordScope, self.key, transformFunction):await()

			if resolved and record ~= nil and record.lock.id == self.ctx.lockId then
				Log.debug(`KeyEntry:lock - Successfully acquired lock for key {self.key}`)
				return record, keyInfo
			end

			Log.trace(`KeyEntry:lock - Failed to acquire lock for key {self.key}, retrying soon. Error: {record}`)
			if i ~= Constants.LOCK_ACQUIRE_ATTEMPTS then
				task.wait(getBackoffTime(Constants.LOCK_DURATION_SECONDS + 5, Constants.LOCK_ACQUIRE_ATTEMPTS - 1, i))
			end
		end
		Log.error(
			`KeyEntry:lock - Failed to acquire lock for key {self.key} after {Constants.LOCK_ACQUIRE_ATTEMPTS} attempts`
		)
		return Promise.reject("Failed to acquire lock") :: any, nil :: any
	end

	self.acquireLockPromise = Promise.try(tryAcquireLock)
		:andThen(function(record: Types.DataStoreRecord, keyInfo: DataStoreKeyInfo)
			if record == nil or record.lock.id ~= self.ctx.lockId then
				Log.error(`KeyEntry:lock - Failed to acquire lock for key {self.key}`)
				return Promise.reject("Failed to acquire lock")
			end

			self.metadata = keyInfo:GetMetadata()
			self.version = record.version or self.ctx.latestVersion

			if record.orphanedFiles then
				self.orphanedFiles = record.orphanedFiles
				self.ctx.orphanedFileQueue:markFiles(self.key, record.orphanedFiles)
			end

			local file = record.file
			if file then
				if isLargeFile(file) then
					self.currentFile = file
				end

				Log.trace(`KeyEntry:lock - Reading data for key {self.key} from file`)
				return self:readLargeFile(file)
			end

			Log.trace(`KeyEntry:lock - No file found for key {self.key}`)
			return nil :: any
		end)
		:andThen(function(txInfo)
			return if txInfo then self:readTx(txInfo) else nil
		end)
		:andThen(function(data)
			if data == nil then
				Log.trace(`KeyEntry:lock - No existing data found for key {self.key}, checking for migration`)
				local migrateFromOtherSystem = self.ctx.migrateFromOtherSystem
				if migrateFromOtherSystem ~= nil then
					Log.trace(`KeyEntry:lock - Migrating data from other system for key {self.key}`)
					data = migrateFromOtherSystem(self.key)
					if data ~= nil then
						self.version = 0
					end
				end
			end
			if data == nil then
				Log.trace(`KeyEntry:lock - No data found for key {self.key}, using template`)
				data = Dictionary.copyDeep(self.ctx.template)
			end

			if self.version > self.ctx.latestVersion then
				Log.error(`KeyEntry:lock - Data for key {self.key} has newer version than this server supports`)
				return Promise.reject("Data has newer version than this server supports")
			elseif self.version < self.ctx.latestVersion then
				Log.trace(`KeyEntry:lock - Migrating data for key {self.key} to latest version`)
				data = self:migrateData(data):expect()
				self.version = self.ctx.latestVersion
			end

			Log.debug(`KeyEntry:lock - Successfully loaded data for key {self.key}, version {self.version}`)
			self.locked = true
			self:mutateKey(data)

			self:startAutosaving()

			return data
		end)
		:finally(function()
			Log.trace(`KeyEntry:lock - Lock acquisition for key {self.key} finished`)
			self.acquireLockPromise = nil
		end)

	return self.acquireLockPromise :: any
end
KeyEntry.lock = t.wrap(KeyEntry.lock, t.tuple(t.any))

function KeyEntry:unlock(): Promise.Promise
	Log.trace(`KeyEntry:unlock called for key {self.key}`)
	return self:waitUntilLocked():andThen(function()
		Log.debug(`KeyEntry:unlock - Unlocking key {self.key}`)
		self.closed = true

		return self.queue:add(function()
			Log.trace(`KeyEntry:unlock - Writing final record for key {self.key}`)
			return self:updateRecord({ releaseLock = true }):andThen(function(latestValue)
				self.ctx.orphanedFileQueue:markFiles(self.key, latestValue.orphanedFiles)
			end)
		end)
	end)
end
KeyEntry.unlock = t.wrap(KeyEntry.unlock, t.tuple(t.any))

function KeyEntry:get<T>(): Promise.TypedPromise<T>
	Log.trace(`KeyEntry:get called for key {self.key}`)
	return self:waitUntilLocked():andThen(function()
		Log.trace(`KeyEntry:get - Returning data for key {self.key}`)
		local data = Dictionary.copyDeep(self.data)
		data = Dictionary.freezeDeep(data :: any)
		return Promise.resolve(data)
	end)
end

function KeyEntry:update<T>(transformFunction: (data: T) -> T?): Promise.Promise
	Log.trace(`KeyEntry:update called for key {self.key}`)
	return self:waitUntilLocked():andThen(function()
		while self.txLockPromise ~= nil do
			Log.trace(`KeyEntry:update - Waiting for ongoing transaction lock for key {self.key}`)
			self.txLockPromise:await()
		end

		local currentData = self.data
		local nextData = Dictionary.copyDeep(currentData)
		local transformOk, result = pcall(noYield, transformFunction, nextData :: any)
		if not transformOk then
			Log.error(`KeyEntry:update - Transform function for key {self.key} failed: {result}`)
			return Promise.reject(`Store:update transformFunction failed: {result}`)
		end

		if result == nil then
			Log.trace(`KeyEntry:update - Skipping update for key {self.key}, transform function returned nil`)
			return nil :: any
		end

		local schemaOk, err = self.ctx.schema(result :: any)
		if not schemaOk then
			Log.error(`KeyEntry:update - Schema validation failed for key {self.key}: {err}`)
			return Promise.reject(`Store:update schema validation failed: {err}`)
		end

		nextData = Dictionary.copyDeep(result)

		if Dictionary.equalsDeep(nextData :: any, currentData :: any) then
			Log.trace(`KeyEntry:update - Skipping update for key {self.key}, data is unchanged`)
			return nil :: any
		end

		Log.trace(`KeyEntry:update - Applying update for key {self.key}`)
		self:mutateKey(nextData)

		return nil :: any
	end) :: Promise.TypedPromise<T>
end
KeyEntry.update = t.wrap(KeyEntry.update, t.tuple(t.any, t.callback))

function KeyEntry:save(): Promise.Promise
	Log.trace(`KeyEntry:save called for key {self.key}`)
	return self:waitUntilLocked():andThen(function()
		if self:isSaved() and not self.refreshLock then
			Log.trace(`KeyEntry:save - Key {self.key} is already saved`)
			return Promise.resolve()
		end
		local snapshot = self:getSnapshot()

		Log.trace(`KeyEntry:save - Queueing save operation for key {self.key}`)
		return self.queue:add(function()
			if self:isSnapshotCommitted(snapshot) and not self.refreshLock then
				Log.trace(`KeyEntry:save - Key {self.key} is already committed, skipping save`)
				return Promise.resolve()
			end

			snapshot = self:getSnapshot()

			Log.trace(`KeyEntry:save - Writing record for key {self.key}`)
			return self:updateRecord({}):andThen(function()
				Log.debug(`KeyEntry:save - Successfully wrote record for key {self.key}, committing snapshot`)
				self:commitSnapshot(snapshot)
			end)
		end)
	end)
end
KeyEntry.save = t.wrap(KeyEntry.save, t.tuple(t.any))

return KeyEntry
