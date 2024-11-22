--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(script.Parent.Constants)
local FileManager = require(script.Parent.FileManager)
local Locks = require(script.Parent.Locks)
local PromiseQueue = require(script.Parent.PromiseQueue)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local t = require(ReplicatedStorage.Packages.t)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local noYield = require(script.Parent.noYield)

local Dictionary = Sift.Dictionary
local Array = Sift.Array
local Set = Sift.Set

type Set = { [string]: boolean }

type KeyEntryImpl<T> = {
	__index: KeyEntryImpl<T>,

	load: (params: LoadKeyEntryParams<T>) -> Promise.TypedPromise<KeyEntry<T>>,

	updateRecord: (self: KeyEntry<T>) -> Promise.TypedPromise<any>,
	writeRecord: (self: KeyEntry<T>, txInfo: Types.TxInfo) -> Promise.TypedPromise<any>,

	isSaved: (self: KeyEntry<T>) -> boolean,

	setData: (self: KeyEntry<T>, data: T) -> (),
	mutateKey: (self: KeyEntry<T>, newData: T) -> (),

	startAutosaving: (self: KeyEntry<T>) -> (),
	stopAutosaving: (self: KeyEntry<T>) -> (),

	unload: (self: KeyEntry<T>) -> Promise.Promise,
	get: (self: KeyEntry<T>) -> Promise.TypedPromise<T>,
	update: (self: KeyEntry<T>, transformFunction: (data: T) -> boolean) -> Promise.Promise,
	save: (self: KeyEntry<T>) -> Promise.Promise,
}

type KeyEntryProps<T> = {
	_cleanupAutosave: (() -> ())?,

	key: string,
	ctx: Types.StoreContext<T>,
	lockHandle: Locks.LockHandle,

	userIds: { number }?,

	data: T?,
	frozenData: T?,
	version: number,

	changeSet: Set,

	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	queue: PromiseQueue.PromiseQueue,
	txLockPromise: Promise.Promise?,

	closed: boolean,
	unloadPromise: Promise.Promise?,

	keyInfo: DataStoreKeyInfo?,

	logger: Types.Logger,
}

export type KeyEntry<T> = typeof(setmetatable({} :: KeyEntryProps<T>, {} :: KeyEntryImpl<T>))

type LoadKeyEntryParams<T> = {
	key: string,
	storeContext: Types.StoreContext<T>,
	userIds: { number }?,
}
local loadKeyEntryParamsCheck = t.strictInterface({
	key = t.string,
	storeContext = t.any,
	userIds = t.optional(t.array(t.number)),
})

export type LoadParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
}

export type LoadResult = {
	data: any,
	version: number,
	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	keyInfo: DataStoreKeyInfo?,
}

local function load(params: LoadParams): any
	local ctx = params.storeContext
	local key = params.key

	local logger = ctx.logger:extend({ method = "load", key = params.key })
	logger:log("trace", `loading key`)

	local recordScope = ctx.recordScope
	local shardScope = ctx.shardScope
	local txScope = ctx.txScope

	local version: number
	local orphanedFiles: { Types.File } = {}
	local currentFile: Types.File?
	local keyInfo: DataStoreKeyInfo?

	return ctx.dataStoreInterface
		:get(recordScope, key)
		:andThen(function(record: Types.DataStoreRecord?, _keyInfo: DataStoreKeyInfo?)
			logger:log("trace", "got record")
			if record == nil then
				record = {} :: Types.DataStoreRecord
			end
			assert(record, "luau")

			keyInfo = _keyInfo
			version = record.version or ctx.latestVersion

			if version > ctx.latestVersion then
				logger:log(
					"error",
					"data has newer version than this server supports",
					{ version = version, latestVersion = ctx.latestVersion }
				)
				return Promise.reject("Data has newer version than this server supports")
			end

			if record.orphanedFiles then
				orphanedFiles = record.orphanedFiles
				ctx.orphanedFileQueue:markFiles(key, record.orphanedFiles)
			end

			local file = record.file
			if file then
				if FileManager.isLargeFile(file) then
					currentFile = file
				end

				logger:log("trace", "reading file", { file = HttpService:JSONEncode(file) })
				local readParams: FileManager.ReadParams = {
					dataStoreInterface = ctx.dataStoreInterface,
					scope = shardScope,
					file = file,
				}
				return FileManager.read(readParams)
			end

			logger:log("trace", "no file")

			return nil :: any
		end)
		:andThen(function(txInfo: Types.TxInfo?): any?
			if txInfo then
				logger:log("trace", "got txInfo", { txInfo = txInfo })

				local readTxParams = {
					dataStoreInterface = ctx.dataStoreInterface,
					scope = txScope,
					txInfo = txInfo,
				}

				return Util.readTx(readTxParams)
			end

			logger:log("trace", "no txInfo")

			return nil
		end)
		:andThen(function(data: any?)
			if data ~= nil then
				logger:log("trace", "got data")
				return data
			end

			local migrateFromOtherSystem = ctx.migrateFromOtherSystem
			if migrateFromOtherSystem == nil then
				logger:log("trace", "no data, no migrateFromOtherSystem")
				return nil
			end

			logger:log("trace", "no data, migrating from other system")
			return Promise.try(migrateFromOtherSystem, key)
				:tap(function(oldData: any?)
					if oldData ~= nil then
						version = 0
					end
					logger:log("trace", "migrated from other system", { oldData = oldData })
				end)
				:catch(function(e)
					logger:log("error", "failed to migrate key from other system", { error = e })
					return Promise.reject(`Failed to migrate key {key} from other system: {e}`)
				end)
		end)
		:andThen(function(data: any?)
			if data == nil then
				logger:log("trace", "no data, using template")
				data = Dictionary.copyDeep(ctx.template)
				version = ctx.latestVersion
			end
			assert(data, "luau")

			if version < ctx.latestVersion then
				logger:log("debug", `migrating data from {version} to {ctx.latestVersion}`)
				local migrateDataParams: Util.MigrateDataParams = {
					fromVersion = version,
					toVersion = ctx.latestVersion,
					data = data,
					migrations = ctx.migrations,
				}
				return Util.migrateData(migrateDataParams):tap(function()
					version = ctx.latestVersion
					logger:log("trace", "data migrated to latest version")
				end)
			end

			logger:log("trace", "data loaded")
			return data
		end)
		:andThen(function(data)
			logger:log("trace", "load done")
			local loadResult: LoadResult = {
				data = data,
				version = version,
				orphanedFiles = orphanedFiles,
				currentFile = currentFile,
				keyInfo = keyInfo,
			}
			return loadResult
		end)
end

local KeyEntry: KeyEntryImpl<any> = {} :: KeyEntryImpl<any>
KeyEntry.__index = KeyEntry

type CreateKeyEntryParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
	lockHandle: Locks.LockHandle,
	userIds: { number }?,
	version: number,
	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	keyInfo: DataStoreKeyInfo?,
}

local function createKeyEntry<T>(params: CreateKeyEntryParams): KeyEntry<T>
	local logger = params.storeContext.logger:extend({ key = params.key })

	local queue = PromiseQueue.new({
		logger = logger:extend({ component = "PromiseQueue" }),
	})

	local props: KeyEntryProps<T> = {
		key = params.key,
		ctx = params.storeContext,
		lockHandle = params.lockHandle,

		userIds = params.userIds,

		data = nil,
		frozenData = nil,
		version = params.version,

		changeSet = {},

		orphanedFiles = params.orphanedFiles,
		currentFile = params.currentFile,

		queue = queue,
		txLockPromise = nil,

		closed = false,
		unloadPromise = nil,

		keyInfo = params.keyInfo,
		logger = logger,
	}

	return setmetatable(props, KeyEntry) :: KeyEntry<T>
end

function KeyEntry.load<T>(params: LoadKeyEntryParams<T>): Promise.TypedPromise<KeyEntry<T>>
	local ctx = params.storeContext
	local logger = ctx.logger:extend({ method = "load", key = params.key })

	local acquireLockParams: Locks.AcquireLockParams = {
		storeContext = ctx,
		key = params.key,
		acquireAttempts = Constants.LOCK_ACQUIRE_ATTEMPTS,
		duration = Constants.LOCK_DURATION_SECONDS,
		refreshInterval = Constants.LOCK_REFRESH_INTERVAL_SECONDS,
	}

	return Locks.acquireLock(acquireLockParams):andThen(function(lockHandle)
		local loadParams = {
			storeContext = ctx,
			key = params.key,
		}

		return load(loadParams):andThen(function(loadResult)
			if not lockHandle.isLocked() then
				logger:log("error", "lock was lost while loading key")
				return Promise.reject("Lock was lost while loading key")
			end

			local createParams: CreateKeyEntryParams = {
				storeContext = ctx,
				key = params.key,
				lockHandle = lockHandle,
				userIds = params.userIds,
				version = loadResult.version,
				orphanedFiles = loadResult.orphanedFiles,
				currentFile = loadResult.currentFile,
				keyInfo = loadResult.keyInfo,
			}

			local keyEntry = createKeyEntry(createParams)

			logger:log("trace", "loaded key", { data = loadResult.data })
			keyEntry:mutateKey(loadResult.data)

			return keyEntry :: any
		end):finally(function(status): ()
			if status ~= (Promise :: any).Status.Resolved then
				logger:log("trace", "failed to load key, releasing lock")
				lockHandle.release():catch(function(e)
					logger:log("warn", "failed to release lock", { error = e })
				end)
			end
		end)
	end)
end
KeyEntry.load = t.wrap(KeyEntry.load, t.tuple(loadKeyEntryParamsCheck))

function KeyEntry:updateRecord(): Promise.TypedPromise<any>
	local logger = self.logger:extend({ method = "updateRecord" })
	logger:log("trace", "updateRecord called")

	if self:isSaved() then
		logger:log("trace", "no changes, returning")
		return Promise.resolve()
	end

	local txInfo = { committedData = Dictionary.copyDeep(self.data) }

	logger:log("trace", "writing record", { txInfo = txInfo })
	return self:writeRecord(txInfo)
end
KeyEntry.updateRecord = t.wrap(KeyEntry.updateRecord, t.tuple(t.any))

function KeyEntry:writeRecord(txInfo: Types.TxInfo): Promise.TypedPromise<any>
	local logger = self.logger:extend({ method = "writeRecord" })
	logger:log("trace", "writeRecord called")

	local function orphanFile(file: Types.File?)
		if file ~= nil and FileManager.isLargeFile(file) then
			table.insert(self.orphanedFiles, file)
			self.ctx.orphanedFileQueue:markFile(self.key, file)
		end
	end

	local writeParams: FileManager.WriteParams = {
		dataStoreInterface = self.ctx.dataStoreInterface,
		data = txInfo,
		maxShardSize = Constants.MAX_CHUNK_SIZE,
		key = self.key,
		scope = self.ctx.shardScope,
		userIds = self.userIds,
	}

	logger:log("trace", "writing file", { writeParams = writeParams })

	return FileManager.write(writeParams)
		:catch(function(err: FileManager.WriteError)
			logger:log("error", "failed to write shards", { error = err.error })

			orphanFile(err.file)

			return Promise.reject(err.error)
		end)
		:andThen(function(file)
			logger:log("trace", "file written", { file = file })

			if not self.lockHandle.isLocked() then
				logger:log("error", "lock was lost while writing file")
				orphanFile(file)
				return Promise.reject("lock was lost while writing file")
			end

			local record = {
				version = self.version,
				file = file,
				orphanedFiles = Array.push(self.orphanedFiles, self.currentFile :: any),
			}

			logger:log("trace", "writing record", { record = record })
			return self.ctx.dataStoreInterface
				:set(self.ctx.recordScope, self.key, record, self.userIds)
				:andThen(function()
					logger:log("trace", "record written")

					orphanFile(self.currentFile)
					self.currentFile = if FileManager.isLargeFile(file) then file else nil

					return record
				end)
				:catch(function(err)
					logger:log("error", "failed to write record", { error = err })

					orphanFile(file)

					return Promise.reject(err)
				end)
		end)
end
KeyEntry.writeRecord = t.wrap(KeyEntry.writeRecord, t.tuple(t.any))

function KeyEntry:isSaved(): boolean
	return Set.count(self.changeSet) == 0
end
KeyEntry.isSaved = t.wrap(KeyEntry.isSaved, t.tuple(t.any))

function KeyEntry:setData(data: any): ()
	local mutationId = HttpService:GenerateGUID(false)
	self.changeSet = Set.add(self.changeSet, mutationId)
	self.data = data
	self.frozenData = Dictionary.freezeDeep(data :: any)
end
KeyEntry.setData = t.wrap(KeyEntry.setData, t.tuple(t.any))

function KeyEntry:mutateKey(newData: any): ()
	local oldData = if self.data then Dictionary.freezeDeep(self.data :: any) else nil

	self:setData(newData)

	for _, callback in self.ctx.changedCallbacks do
		task.spawn(callback, self.key, self.frozenData, oldData)
	end
end
KeyEntry.mutateKey = t.wrap(KeyEntry.mutateKey, t.tuple(t.any, t.any))

function KeyEntry:startAutosaving(): ()
	local logger = self.logger:extend({ method = "startAutosaving" })

	if self._cleanupAutosave then
		logger:log("warn", "autosave already started")
		return
	end
	if self.closed then
		logger:log("warn", "KeyEntry is closed, not starting autosave")
		return
	end

	local stop = false

	task.spawn(function()
		while true do
			task.wait(Constants.AUTOSAVE_INTERVAL_SECONDS)
			if self.closed or stop then
				break
			end

			local ok, err = self:save():await()
			if not ok then
				logger:log("warn", "failed to autosave key", { error = err })
			end
		end
	end)

	local disconnectOnLockLost = self.lockHandle.onLockLost(function()
		logger:log("warn", "lock was lost, stopping autosave")
		self:stopAutosaving()
	end)

	self._cleanupAutosave = function()
		logger:log("trace", "cleaning up autosave")
		stop = true
		disconnectOnLockLost()
		self._cleanupAutosave = nil
	end
end
KeyEntry.startAutosaving = t.wrap(KeyEntry.startAutosaving, t.tuple(t.any))

function KeyEntry:stopAutosaving(): ()
	if self._cleanupAutosave then
		self._cleanupAutosave()
	end
end
KeyEntry.stopAutosaving = t.wrap(KeyEntry.stopAutosaving, t.tuple(t.any))

function KeyEntry:unload(): Promise.Promise
	local logger = self.logger:extend({ method = "unload" })
	logger:log("trace", "unload called")

	if self.unloadPromise then
		logger:log("trace", "unload already in progress")
		return self.unloadPromise
	end

	self.closed = true
	self:stopAutosaving()

	logger:log("trace", "queueing unload")
	self.unloadPromise = self.queue
		:add(function()
			logger:log("trace", "updating record before unloading")
			return self:updateRecord()
		end)
		:finally(function()
			logger:log("trace", "releasing lock")
			return self.lockHandle.release():catch(function(e)
				logger:log("warn", "failed to release lock", { error = e })
			end)
		end)

	return self.unloadPromise :: any
end
KeyEntry.unload = t.wrap(KeyEntry.unload, t.tuple(t.any))

function KeyEntry:get<T>(): Promise.TypedPromise<T>
	return Promise.resolve(self.frozenData) :: any
end
KeyEntry.get = t.wrap(KeyEntry.get, t.tuple(t.any))

function KeyEntry:update<T>(transformFunction: (data: T) -> boolean): Promise.Promise
	local logger = self.logger:extend({ method = "update" })
	logger:log("trace", "update called")

	if self.closed then
		logger:log("warn", "KeyEntry is closed, skipping update")
		return Promise.reject("KeyEntry is closed")
	end

	return Promise.new(function(resolve, reject)
		while self.txLockPromise ~= nil do
			self.txLockPromise:await()
		end
		logger:log("trace", `UPDATING KEY`)

		local currentData = self.data
		local nextData = Dictionary.copyDeep(currentData)

		local transformOk, result = pcall(noYield, transformFunction, nextData :: any)
		if not transformOk then
			logger:log("error", "transformFunction failed", { error = result })
			return reject(`transformFunction failed: {result}`)
		end

		if typeof(result) ~= "boolean" then
			logger:log("error", "transformFunction must return a boolean")
			return reject("transformFunction must return a boolean")
		end

		if result == false then
			logger:log("trace", "transformFunction returned false, skipping update")
			return resolve()
		end

		-- We deep copy here to prevent references to internal state from being
		-- leaked. If we didn't, the transform function could modify the state
		-- after it runs, which shouldn't be allowed.
		nextData = Dictionary.copyDeep(nextData)

		local schemaOk, err = self.ctx.schema(nextData :: any)
		if not schemaOk then
			logger:log("error", "schema validation failed", { error = err })
			return reject(`Store:update schema validation failed: {err}`)
		end

		if Dictionary.equalsDeep(nextData :: any, currentData :: any) then
			return resolve()
		end

		self:mutateKey(nextData)

		logger:log("trace", "update succeeded")

		return resolve()
	end)
end
KeyEntry.update = t.wrap(KeyEntry.update, t.tuple(t.any, t.callback))

function KeyEntry:save(): Promise.Promise
	local logger = self.logger:extend({ method = "save" })
	logger:log("trace", "save called")

	if self.closed then
		logger:log("warn", "KeyEntry is closed, skipping save")
		return Promise.reject("KeyEntry is closed")
	end
	if self:isSaved() then
		logger:log("trace", "no changes, returning")
		return Promise.resolve()
	end

	local changes = Set.copy(self.changeSet)

	logger:log("trace", "queueing save")
	return self.queue:add(function()
		logger:log("trace", "save task running")

		local changesWereSaved = Set.count(Set.intersection(changes, self.changeSet)) == 0
		if changesWereSaved then
			logger:log("trace", "changes were saved by another task, returning")
			return Promise.resolve()
		end

		changes = Set.copy(self.changeSet)

		logger:log("trace", "saving changes", { changes = changes })
		return self:updateRecord():andThen(function()
			local newChangeSet = Set.difference(self.changeSet, changes)

			logger:log("trace", "changes saved", { latestChanges = self.changeSet, newChanges = newChangeSet })

			self.changeSet = newChangeSet
		end)
	end)
end
KeyEntry.save = t.wrap(KeyEntry.save, t.tuple(t.any))

return KeyEntry
