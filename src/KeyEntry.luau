--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(script.Parent.Constants)
local PromiseQueue = require(script.Parent.PromiseQueue)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local t = require(ReplicatedStorage.Packages.t)
local Types = require(script.Parent.Types)
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
	updateRecord: (self: KeyEntry<T>) -> Promise.TypedPromise<any>,
	writeRecord: (self: KeyEntry<T>, txInfo: Types.TxInfo) -> Promise.TypedPromise<any>,

	getLock: (self: KeyEntry<T>) -> Types.LockInfo,

	getSnapshot: (self: KeyEntry<T>) -> UnsavedMutationsSnapshot,
	isSnapshotCommitted: (self: KeyEntry<T>, snapshot: UnsavedMutationsSnapshot) -> boolean,
	commitSnapshot: (self: KeyEntry<T>, snapshot: UnsavedMutationsSnapshot) -> (),
	isSaved: (self: KeyEntry<T>) -> boolean,

	mutateKey: (self: KeyEntry<T>, newData: T) -> (),
	migrateData: (self: KeyEntry<T>, data: any) -> Promise.TypedPromise<any>,

	waitUntilLoaded: (self: KeyEntry<T>) -> Promise.Promise,
	startAutosaving: (self: KeyEntry<T>) -> (),
	startRefreshingLock: (self: KeyEntry<T>) -> (),

	lock: (self: KeyEntry<T>) -> Promise.Promise,
	unlock: (self: KeyEntry<T>) -> Promise.Promise,

	load: (self: KeyEntry<T>) -> Promise.Promise,
	unload: (self: KeyEntry<T>) -> Promise.Promise,
	get: (self: KeyEntry<T>) -> Promise.TypedPromise<T>,
	update: (self: KeyEntry<T>, transformFunction: (data: T) -> boolean) -> Promise.Promise,
	save: (self: KeyEntry<T>) -> Promise.Promise,
}

type KeyEntryProps<T> = {
	key: string,
	ctx: Types.StoreContext<T>,

	userIds: { number }?,
	metadata: { [string]: any }?,

	data: T?,
	frozenData: T?,
	version: number,

	unsavedMutations: UnsavedMutationsSnapshot,

	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	queue: PromiseQueue.PromiseQueue,
	txLockPromise: Promise.Promise?,

	closed: boolean,
	locked: boolean,
	loaded: boolean,
	loadPromise: Promise.Promise?,
	refreshLock: boolean,
	lockExpiryThread: thread?,

	recordScope: string,
	shardScope: string,
	txScope: string,
	lockScope: string,
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
	local ctx = config.storeContext

	ctx.log("trace", `Creating new KeyEntry for key {config.key}`)
	return setmetatable({
		key = config.key,
		ctx = ctx,

		userIds = config.userIds,

		data = nil,
		frozenData = nil,
		version = config.storeContext.latestVersion,

		unsavedMutations = {},

		orphanedFiles = {},
		currentFile = nil,
		queue = PromiseQueue.new(),
		txLockPromise = nil,

		closed = false,
		locked = false,
		loaded = false,
		loadPromise = nil,
		refreshLock = false,
		lockExpiryThread = nil,

		recordScope = `{Constants.RECORD_SCOPE}/{config.storeContext.name}`,
		shardScope = `{Constants.SHARD_SCOPE}/{config.storeContext.name}`,
		txScope = `{Constants.TX_SCOPE}/{config.storeContext.name}`,
		lockScope = `{Constants.LOCK_SCOPE}/{config.storeContext.name}`,
	}, KeyEntry) :: KeyEntry<T>
end
KeyEntry.new = t.wrap(KeyEntry.new, t.tuple(keyEntryConfigCheck))

-- TODO: Update data: any to a more specific type
function KeyEntry:writeLargeFile(data: any): Promise.TypedPromise<Types.File>
	self.ctx.log("trace", `KeyEntry:writeLargeFile called for key {self.key}`)
	local str = HttpService:JSONEncode(data)
	if #str <= Constants.MAX_CHUNK_SIZE then
		self.ctx.log("trace", `KeyEntry:writeLargeFile - Data for key {self.key} is small, not sharding`)
		return Promise.resolve({ data = data } :: Types.File)
	end

	local shardId = HttpService:GenerateGUID(false)
	self.ctx.log("debug", `KeyEntry:writeLargeFile - Data for key {self.key} is large, sharding with ID {shardId}`)

	-- TODO: Add a test case ensuring that splitUtf8String is called with the correct arguments
	local shards = splitUtf8String(str, Constants.MAX_CHUNK_SIZE)
	self.ctx.log("debug", `KeyEntry:writeLargeFile - Split data for key {self.key} into {#shards} shards`)

	local promises = Array.map(shards, function(shard, index)
		self.ctx.log("trace", `KeyEntry:writeLargeFile - Writing shard {index} for key {self.key}`)
		return self.ctx.dataStoreInterface:set(self.shardScope, `{shardId}-{index}`, shard, self.userIds)
	end)

	local file = { shard = shardId, count = #shards }

	local p = Promise.all(promises):andThenReturn(file):catch(function(err)
		self.ctx.log("error", `KeyEntry:writeLargeFile - Failed to write shards for key {self.key}: {err}`)
		table.insert(self.orphanedFiles, file)
		self.ctx.orphanedFileQueue:markFile(self.key, file)
		return Promise.reject(err)
	end)

	return p
end
-- TODO: Update data: any to a more specific type
KeyEntry.writeLargeFile = t.wrap(KeyEntry.writeLargeFile, t.tuple(t.any, t.any, t.optional(t.map(t.string, t.any))))

function KeyEntry:readLargeFile(file: Types.File): Promise.TypedPromise<any>
	self.ctx.log("trace", `KeyEntry:readLargeFile called for key {self.key}`)
	if not isLargeFile(file) then
		self.ctx.log("trace", `KeyEntry:readLargeFile - File for key {self.key} is not sharded`)
		return Promise.resolve(file.data)
	end

	local shardId = file.shard
	self.ctx.log("debug", `KeyEntry:readLargeFile - Reading sharded file for key {self.key} with ID {shardId}`)

	local promises = {}

	for i = 1, file.count do
		self.ctx.log("trace", `KeyEntry:readLargeFile - Reading shard {i} for key {self.key}`)
		table.insert(promises, self.ctx.dataStoreInterface:get(self.shardScope, `{shardId}-{i}`))
	end

	return Promise.all(promises):andThen(function(shards)
		self.ctx.log("trace", `KeyEntry:readLargeFile - Assembling {file.count} shards for key {self.key}`)
		return HttpService:JSONDecode(table.concat(shards))
	end)
end
KeyEntry.readLargeFile = t.wrap(KeyEntry.readLargeFile, t.tuple(t.any, Types.fileCheck))

function KeyEntry:readTx(txInfo: Types.TxInfo): Promise.TypedPromise<any>
	self.ctx.log("trace", `KeyEntry:readTx called for key {self.key}`)
	local txId = txInfo.txId
	if txId == nil then
		self.ctx.log("trace", `KeyEntry:readTx - No txId for key {self.key}, returning committedData`)
		return Promise.resolve(txInfo.committedData)
	end

	self.ctx.log("debug", `KeyEntry:readTx - Reading transaction data for key {self.key} with ID {txId}`)
	return self.ctx.dataStoreInterface:get(self.txScope, txId):andThen(function(committed)
		if committed == true then
			self.ctx.log(
				"trace",
				`KeyEntry:readTx - Transaction {txId} for key {self.key} is committed, returning txData`
			)
			return txInfo.txData
		else
			self.ctx.log(
				"trace",
				`KeyEntry:readTx - Transaction {txId} for key {self.key} is not committed, returning committedData`
			)
			return txInfo.committedData
		end
	end)
end
KeyEntry.readTx = t.wrap(KeyEntry.readTx, t.tuple(t.any, Types.txInfoCheck))

function KeyEntry:updateRecord(): Promise.TypedPromise<any>
	self.ctx.log("trace", `KeyEntry:updateRecord called for key {self.key}`)

	if self:isSaved() then
		return Promise.resolve()
	end

	local txInfo = { committedData = Dictionary.copyDeep(self.data) }

	return self:writeRecord(txInfo)
end
KeyEntry.updateRecord = t.wrap(KeyEntry.updateRecord, t.tuple(t.any))

function KeyEntry:writeRecord(txInfo: Types.TxInfo): Promise.TypedPromise<any>
	self.ctx.log("trace", `KeyEntry:writeRecord called for key {self.key}`)

	return self:writeLargeFile(txInfo):andThen(function(file)
		local orphanedFiles = Array.push(self.orphanedFiles, self.currentFile :: any)

		local record = {
			version = self.version,
			file = file,
			orphanedFiles = orphanedFiles,
		}

		return self.ctx.dataStoreInterface
			:set(self.recordScope, self.key, record, self.userIds)
			:andThen(function()
				self.ctx.log("debug", `KeyEntry:writeRecord - Successfully wrote record for key {self.key}`)
				self.orphanedFiles = orphanedFiles
				self.currentFile = if isLargeFile(file) then file else nil
				if self.currentFile then
					self.ctx.orphanedFileQueue:markFile(self.key, self.currentFile)
				end

				return record
			end)
			:catch(function(err)
				self.ctx.log("error", `KeyEntry:writeRecord - Failed to write record for key {self.key}: {err}`)
				if isLargeFile(file) then
					table.insert(self.orphanedFiles, file)
					self.ctx.orphanedFileQueue:markFile(self.key, file)
				end

				return Promise.reject(err)
			end)
	end)
end
KeyEntry.writeRecord = t.wrap(KeyEntry.writeRecord, t.tuple(t.any))

function KeyEntry:getLock(): Types.LockInfo
	self.ctx.log("trace", `KeyEntry:getLock called for key {self.key}`)
	return {
		id = self.ctx.lockId,
		expiry = DateTime.now().UnixTimestamp + Constants.LOCK_DURATION_SECONDS,
	}
end
KeyEntry.getLock = t.wrap(KeyEntry.getLock, t.tuple(t.any))

function KeyEntry:getSnapshot(): UnsavedMutationsSnapshot
	self.ctx.log("trace", `KeyEntry:getSnapshot called for key {self.key}`)
	return Set.copy(self.unsavedMutations)
end
KeyEntry.getSnapshot = t.wrap(KeyEntry.getSnapshot, t.tuple(t.any))

function KeyEntry:isSnapshotCommitted(snapshot: UnsavedMutationsSnapshot): boolean
	self.ctx.log("trace", `KeyEntry:isSnapshotCommitted called for key {self.key}`)
	local intersection = Set.intersection(snapshot, self.unsavedMutations)
	return Set.count(intersection) == 0
end
KeyEntry.isSnapshotCommitted = t.wrap(KeyEntry.isSnapshotCommitted, t.tuple(t.any, unsavedMutationsSnapshotCheck))

function KeyEntry:commitSnapshot(snapshot: UnsavedMutationsSnapshot): ()
	self.ctx.log("trace", `KeyEntry:commitSnapshot called for key {self.key}`)
	self.unsavedMutations = Set.difference(self.unsavedMutations, snapshot)
end
KeyEntry.commitSnapshot = t.wrap(KeyEntry.commitSnapshot, t.tuple(t.any, unsavedMutationsSnapshotCheck))

function KeyEntry:isSaved(): boolean
	self.ctx.log("trace", `KeyEntry:isSaved called for key {self.key}`)
	return Set.count(self.unsavedMutations) == 0
end
KeyEntry.isSaved = t.wrap(KeyEntry.isSaved, t.tuple(t.any))

function KeyEntry:mutateKey(newData: any): ()
	self.ctx.log("trace", `KeyEntry:mutateKey called for key {self.key}`)
	local oldData = if self.data then Dictionary.freezeDeep(self.data :: any) else nil

	local mutationId = HttpService:GenerateGUID(false)
	self.unsavedMutations = Set.add(self.unsavedMutations, mutationId)
	self.data = newData
	self.frozenData = Dictionary.freezeDeep(newData :: any)

	self.ctx.log("debug", `KeyEntry:mutateKey - Mutated key {self.key} with new data`)

	for _, callback in self.ctx.changedCallbacks do
		task.spawn(callback, self.key, self.frozenData, oldData)
	end
end
KeyEntry.mutateKey = t.wrap(KeyEntry.mutateKey, t.tuple(t.any, t.any))

function KeyEntry:migrateData(data: any): Promise.TypedPromise<any>
	self.ctx.log("trace", `KeyEntry:migrateData called for key {self.key}`)
	data = Dictionary.copyDeep(data)
	return Promise.new(function(resolve)
		for i = self.version + 1, self.ctx.latestVersion do
			self.ctx.log("trace", `KeyEntry:migrateData - Migrating key {self.key} from version {i - 1} to {i}`)
			local migration = self.ctx.migrations[i]
			if migration then
				local newData = Promise.try(migration, data):expect()
				data = Dictionary.copyDeep(newData)
			end
		end
		self.ctx.log("debug", `KeyEntry:migrateData - Migrated key {self.key} to version {self.ctx.latestVersion}`)

		resolve(data)
	end)
end
KeyEntry.migrateData = t.wrap(KeyEntry.migrateData, t.tuple(t.any, t.any))

function KeyEntry:waitUntilLoaded(): Promise.Promise
	self.ctx.log("trace", `KeyEntry:waitUntilLoaded called for key {self.key}`)
	return Promise.resolve(self.loadPromise):andThen(function()
		if self.closed then
			self.ctx.log("error", `KeyEntry:waitUntilLoaded - KeyEntry for key {self.key} is closed`)
			return Promise.reject("KeyEntry is closed")
		end
		if not self.locked then
			self.ctx.log("error", `KeyEntry:waitUntilLoaded - KeyEntry for key {self.key} is not locked`)
			return Promise.reject("KeyEntry is not locked")
		end
		if not self.loaded then
			self.ctx.log("error", `KeyEntry:waitUntilLoaded - KeyEntry for key {self.key} is not loaded`)
			return Promise.reject("KeyEntry is not loaded")
		end
	end)
end
KeyEntry.waitUntilLoaded = t.wrap(KeyEntry.waitUntilLoaded, t.tuple(t.any))

function KeyEntry:startAutosaving(): ()
	self.ctx.log("trace", `KeyEntry:startAutosaving - Starting autosave for key {self.key}`)
	task.spawn(function()
		while true do
			task.wait(Constants.AUTOSAVE_INTERVAL_SECONDS)
			if self.closed then
				self.ctx.log(
					"trace",
					`KeyEntry:startAutosaving - Autosave loop for key {self.key} exiting, KeyEntry is closed`
				)
				break
			end

			self.ctx.log("trace", `KeyEntry:startAutosaving - Autosaving key {self.key}`)
			local ok, err = self:save():await()
			if not ok then
				self.ctx.log("warn", `KeyEntry:startAutosaving - Failed to autosave key {self.key}: {err}`)
			end
		end
	end)
end
KeyEntry.startAutosaving = t.wrap(KeyEntry.startAutosaving, t.tuple(t.any))

function KeyEntry:startRefreshingLock(): ()
	self.ctx.log("trace", `KeyEntry:startRefreshingLock - Starting lock refresh for key {self.key}`)
	task.spawn(function()
		while true do
			task.wait(Constants.LOCK_REFRESH_INTERVAL_SECONDS)

			if self.closed then
				self.ctx.log(
					"trace",
					`KeyEntry:startRefreshingLock - Lock refresh loop for key {self.key} exiting, KeyEntry is closed`
				)
				break
			end

			self.ctx.log("trace", `KeyEntry:startRefreshingLock - Refreshing lock for key {self.key}`)

			local resolved, err = self:lock():await()

			if not resolved then
				self.ctx.log("warn", `KeyEntry:startRefreshingLock - Failed to refresh lock for key {self.key}: {err}`)
				self:unlock()
				break
			end
		end
	end)
end
KeyEntry.startRefreshingLock = t.wrap(KeyEntry.startRefreshingLock, t.tuple(t.any))

function KeyEntry:lock(): Promise.Promise
	local function transformFunction(lock: Types.LockInfo?): Types.LockInfo?
		if lock == nil then
			return self:getLock()
		end

		if lock.id ~= self.ctx.lockId and lock.expiry > DateTime.now().UnixTimestamp then
			self.ctx.log("trace", `KeyEntry:lock - Lock for key {self.key} is still valid, aborting lock acquisition`)
			return nil
		end

		self.ctx.log("trace", `KeyEntry:lock - Acquiring lock for key {self.key}`)
		return self:getLock()
	end

	return Promise.new(function(resolve, reject)
		for i = 1, Constants.LOCK_ACQUIRE_ATTEMPTS do
			self.ctx.log(
				"trace",
				`KeyEntry:lock - Attempting to acquire lock for key {self.key}, attempt {i}/{Constants.LOCK_ACQUIRE_ATTEMPTS}`
			)
			local resolved, lastValue = self.ctx.hashMapInterface
				:update(self.lockScope, self.key, transformFunction, Constants.LOCK_DURATION_SECONDS)
				:await()

			if resolved and lastValue ~= nil then
				self.ctx.log("debug", `KeyEntry:lock - Successfully acquired lock for key {self.key}`)
				return resolve()
			end

			if i ~= Constants.LOCK_ACQUIRE_ATTEMPTS then
				local retryAfter = math.min(2 ^ (i - 1), 30)
				self.ctx.log(
					"trace",
					`KeyEntry:lock - Failed to acquire lock for key {self.key}, retrying in {retryAfter} seconds`
				)
				task.wait(retryAfter)
			end
		end

		self.ctx.log(
			"error",
			`KeyEntry:lock - Failed to acquire lock for key {self.key} after {Constants.LOCK_ACQUIRE_ATTEMPTS} attempts`
		)
		return reject("Failed to acquire lock")
	end):tap(function()
		if self.lockExpiryThread then
			task.cancel(self.lockExpiryThread)
		end

		self.lockExpiryThread = task.delay(Constants.LOCK_DURATION_SECONDS, function()
			self.ctx.log("trace", `KeyEntry:lock - Lock for key {self.key} expired, releasing lock`)
			self:unlock()
		end)

		self.locked = true
	end)
end
KeyEntry.lock = t.wrap(KeyEntry.lock, t.tuple(t.any))

function KeyEntry:unlock(): Promise.Promise
	self.ctx.log("trace", `KeyEntry:unlock called for key {self.key}`)

	if not self.locked then
		return Promise.reject("KeyEntry is not locked")
	end

	return self.ctx.hashMapInterface:remove(self.lockScope, self.key):tap(function()
		if self.lockExpiryThread then
			task.cancel(self.lockExpiryThread)
			self.lockExpiryThread = nil
		end

		self.locked = false
	end)
end
KeyEntry.unlock = t.wrap(KeyEntry.unlock, t.tuple(t.any))

function KeyEntry:load(): Promise.Promise
	self.ctx.log("trace", `KeyEntry:load called for key {self.key}`)
	if self.loaded then
		self.ctx.log("warn", `KeyEntry:load - KeyEntry for key {self.key} is already loaded`)
		return Promise.reject("KeyEntry is already loaded")
	end
	if self.closed then
		self.ctx.log("warn", `KeyEntry:load - KeyEntry for key {self.key} is closed`)
		return Promise.reject("KeyEntry is closed")
	end
	if self.loadPromise then
		self.ctx.log("trace", `KeyEntry:load - KeyEntry for key {self.key} is already being loaded`)
		return Promise.reject("KeyEntry is already being loaded")
	end

	self.loadPromise = self:lock()
		:andThen(function()
			self:startRefreshingLock()
			return self.ctx.dataStoreInterface:get(self.recordScope, self.key)
		end)
		:andThen(function(record: any?)
			if record == nil then
				record = {}
			end

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

				self.ctx.log("trace", `KeyEntry:lock - Reading data for key {self.key} from file`)
				return self:readLargeFile(file)
			end

			self.ctx.log("trace", `KeyEntry:lock - No file found for key {self.key}`)
			return nil :: any
		end)
		:andThen(function(txInfo)
			return if txInfo then self:readTx(txInfo) else nil
		end)
		:andThen(function(data)
			if data == nil then
				self.ctx.log(
					"trace",
					`KeyEntry:lock - No existing data found for key {self.key}, checking for migration`
				)
				local migrateFromOtherSystem = self.ctx.migrateFromOtherSystem
				if migrateFromOtherSystem ~= nil then
					self.ctx.log("trace", `KeyEntry:lock - Migrating data from other system for key {self.key}`)
					data = migrateFromOtherSystem(self.key)
					if data ~= nil then
						self.version = 0
					end
				end
			end

			if data == nil then
				self.ctx.log("trace", `KeyEntry:lock - No data found for key {self.key}, using template`)
				data = Dictionary.copyDeep(self.ctx.template)
			end

			if self.version > self.ctx.latestVersion then
				self.ctx.log(
					"error",
					`KeyEntry:lock - Data for key {self.key} has newer version than this server supports`
				)
				return Promise.reject("Data has newer version than this server supports")
			elseif self.version < self.ctx.latestVersion then
				self.ctx.log("trace", `KeyEntry:lock - Migrating data for key {self.key} to latest version`)
				data = self:migrateData(data):expect()
				self.version = self.ctx.latestVersion
			end

			self.ctx.log("debug", `KeyEntry:lock - Successfully loaded data for key {self.key}, version {self.version}`)
			self.loaded = true
			self:mutateKey(data)

			self:startAutosaving()

			return data
		end)
		:finally(function()
			self.ctx.log("trace", `KeyEntry:lock - Lock acquisition for key {self.key} finished`)
			self.loadPromise = nil
		end)

	return self.loadPromise :: any
end
KeyEntry.load = t.wrap(KeyEntry.load, t.tuple(t.any))

function KeyEntry:unload(): Promise.Promise
	self.ctx.log("trace", `KeyEntry:unload called for key {self.key}`)
	return self:waitUntilLoaded()
		:andThen(function()
			self.ctx.log("debug", `KeyEntry:unload - Unlocking key {self.key}`)
			self.closed = true

			return self.queue:add(function()
				self.ctx.log("trace", `KeyEntry:unload - Writing final record for key {self.key}`)
				return self:updateRecord()
			end)
		end)
		:andThen(function()
			return self:unlock()
		end)
end
KeyEntry.unload = t.wrap(KeyEntry.unload, t.tuple(t.any))

function KeyEntry:get<T>(): Promise.TypedPromise<T>
	self.ctx.log("trace", `KeyEntry:get called for key {self.key}`)
	return self:waitUntilLoaded():andThen(function()
		self.ctx.log("trace", `KeyEntry:get - Returning data for key {self.key}`)

		return Promise.resolve(self.frozenData)
	end)
end
KeyEntry.get = t.wrap(KeyEntry.get, t.tuple(t.any))

function KeyEntry:update<T>(transformFunction: (data: T) -> T?): Promise.Promise
	self.ctx.log("trace", `KeyEntry:update called for key {self.key}`)
	return self:waitUntilLoaded():andThen(function()
		while self.txLockPromise ~= nil do
			self.ctx.log("trace", `KeyEntry:update - Waiting for ongoing transaction lock for key {self.key}`)
			self.txLockPromise:await()
		end

		local currentData = self.data
		local nextData = Dictionary.copyDeep(currentData)
		local transformOk, result = pcall(noYield, transformFunction, nextData :: any)
		if not transformOk then
			self.ctx.log("error", `KeyEntry:update - Transform function for key {self.key} failed: {result}`)
			return Promise.reject(`Store:update transformFunction failed: {result}`)
		end

		assert(typeof(result) == "boolean", "Transform function must return a boolean")

		if result == false then
			self.ctx.log(
				"trace",
				`KeyEntry:update - Skipping update for key {self.key}, transform function returned false`
			)
			return nil :: any
		end

		-- We deep copy here to prevent references to internal state from being
		-- leaked. If we didn't, the transform function could modify the state
		-- after it runs, which shouldn't be allowed.
		nextData = Dictionary.copyDeep(nextData)

		local schemaOk, err = self.ctx.schema(nextData :: any)
		if not schemaOk then
			self.ctx.log("error", `KeyEntry:update - Schema validation failed for key {self.key}: {err}`)
			return Promise.reject(`Store:update schema validation failed: {err}`)
		end

		if Dictionary.equalsDeep(nextData :: any, currentData :: any) then
			self.ctx.log("trace", `KeyEntry:update - Skipping update for key {self.key}, data is unchanged`)
			return nil :: any
		end

		self.ctx.log("trace", `KeyEntry:update - Applying update for key {self.key}`)
		self:mutateKey(nextData)

		return nil :: any
	end) :: Promise.TypedPromise<T>
end
KeyEntry.update = t.wrap(KeyEntry.update, t.tuple(t.any, t.callback))

function KeyEntry:save(): Promise.Promise
	self.ctx.log("trace", `KeyEntry:save called for key {self.key}`)
	return self:waitUntilLoaded():andThen(function()
		if self:isSaved() then
			self.ctx.log("trace", `KeyEntry:save - Key {self.key} is already saved`)
			return Promise.resolve()
		end
		local snapshot = self:getSnapshot()

		self.ctx.log("trace", `KeyEntry:save - Queueing save operation for key {self.key}`)
		return self.queue:add(function()
			if self:isSnapshotCommitted(snapshot) then
				self.ctx.log("trace", `KeyEntry:save - Key {self.key} is already committed, skipping save`)
				return Promise.resolve()
			end

			snapshot = self:getSnapshot()

			self.ctx.log("trace", `KeyEntry:save - Writing record for key {self.key}`)
			return self:updateRecord():andThen(function()
				self.ctx.log(
					"debug",
					`KeyEntry:save - Successfully wrote record for key {self.key}, committing snapshot`
				)
				self:commitSnapshot(snapshot)
			end)
		end)
	end)
end
KeyEntry.save = t.wrap(KeyEntry.save, t.tuple(t.any))

return KeyEntry
