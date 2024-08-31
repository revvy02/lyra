--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(script.Parent.Constants)
local FileManager = require(script.Parent.FileManager)
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
	lockHandle: Util.LockHandle,

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
}

local function load(params: LoadParams): any
	local ctx = params.storeContext
	local key = params.key

	local recordScope = ctx.recordScope
	local shardScope = ctx.shardScope
	local txScope = ctx.txScope

	local version: number
	local orphanedFiles: { Types.File } = {}
	local currentFile: Types.File?

	return ctx.dataStoreInterface
		:get(recordScope, key)
		:andThen(function(record: Types.DataStoreRecord?)
			if record == nil then
				record = {} :: Types.DataStoreRecord
			end
			assert(record, "luau")

			version = record.version or ctx.latestVersion

			if record.orphanedFiles then
				orphanedFiles = record.orphanedFiles
				ctx.orphanedFileQueue:markFiles(key, record.orphanedFiles)
			end

			local file = record.file
			if file then
				if FileManager.isLargeFile(file) then
					currentFile = file
				end

				local readParams: FileManager.ReadParams = {
					dataStoreInterface = ctx.dataStoreInterface,
					scope = shardScope,
					file = file,
				}
				return FileManager.read(readParams)
			end

			return nil :: any
		end)
		:andThen(function(txInfo: Types.TxInfo?): any?
			if txInfo then
				local readTxParams = {
					dataStoreInterface = ctx.dataStoreInterface,
					scope = txScope,
					txInfo = txInfo,
				}
				return Util.readTx(readTxParams)
			end
			return nil
		end)
		:andThen(function(data: any?)
			if data ~= nil then
				return data
			end

			local migrateFromOtherSystem = ctx.migrateFromOtherSystem
			if migrateFromOtherSystem == nil then
				return nil
			end

			return Promise.try(migrateFromOtherSystem, key)
				:tap(function(oldData: any?)
					if oldData ~= nil then
						version = 0
					end
				end)
				:catch(function(e)
					return Promise.reject(`Failed to migrate key {key} from other system: {e}`)
				end)
		end)
		:andThen(function(data: any?)
			if data == nil then
				data = Dictionary.copyDeep(ctx.template)
				version = ctx.latestVersion
			end
			assert(data, "luau")

			if version > ctx.latestVersion then
				ctx.log("error", `KeyEntry:lock - Data for key {key} has newer version than this server supports`)
				return Promise.reject("Data has newer version than this server supports")
			elseif version < ctx.latestVersion then
				local migrateDataParams: Util.MigrateDataParams = {
					fromVersion = version,
					toVersion = ctx.latestVersion,
					data = data,
					migrations = ctx.migrations,
				}
				return Util.migrateData(migrateDataParams):tap(function()
					version = ctx.latestVersion
				end)
			end

			return data
		end)
		:andThen(function(data)
			local loadResult: LoadResult = {
				data = data,
				version = version,
				orphanedFiles = orphanedFiles,
				currentFile = currentFile,
			}
			return loadResult
		end)
end

local KeyEntry: KeyEntryImpl<any> = {} :: KeyEntryImpl<any>
KeyEntry.__index = KeyEntry

type CreateKeyEntryParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
	lockHandle: Util.LockHandle,
	userIds: { number }?,
	version: number,
	orphanedFiles: { Types.File },
	currentFile: Types.File?,
}

local function createKeyEntry<T>(params: CreateKeyEntryParams): KeyEntry<T>
	local ctx = params.storeContext

	local queue = PromiseQueue.new()
	queue.onTimeout = function(e)
		ctx.log("error", `PromiseQueue timed out: {e}`)
	end

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
	}

	return setmetatable(props, KeyEntry) :: KeyEntry<T>
end

function KeyEntry.load<T>(params: LoadKeyEntryParams<T>): Promise.TypedPromise<KeyEntry<T>>
	local ctx = params.storeContext

	local acquireLockParams: Util.AcquireLockParams = {
		storeContext = ctx,
		key = params.key,
		acquireAttempts = Constants.LOCK_ACQUIRE_ATTEMPTS,
		duration = Constants.LOCK_DURATION_SECONDS,
		refreshInterval = Constants.LOCK_REFRESH_INTERVAL_SECONDS,
	}

	return Util.acquireLock(acquireLockParams):andThen(function(lockHandle)
		local loadParams = {
			storeContext = ctx,
			key = params.key,
		}

		return load(loadParams):andThen(function(loadResult)
			if not lockHandle.isLocked() then
				return Promise.reject("KeyEntry:load - Lock was lost while loading key")
			end

			local createParams: CreateKeyEntryParams = {
				storeContext = ctx,
				key = params.key,
				lockHandle = lockHandle,
				userIds = params.userIds,
				version = loadResult.version,
				orphanedFiles = loadResult.orphanedFiles,
				currentFile = loadResult.currentFile,
			}

			local keyEntry = createKeyEntry(createParams)

			keyEntry:mutateKey(loadResult.data)

			return keyEntry :: any
		end):finally(function(status): ()
			if status ~= (Promise :: any).Status.Resolved then
				ctx.log("warn", `KeyEntry:load - Failed to load key {params.key}: {status}, releasing`)
				lockHandle.release():catch(function(e)
					ctx.log("warn", `KeyEntry:load - Failed to release lock for key {params.key}: {e}`)
				end)
				return Promise.reject("Failed to load key")
			end
		end)
	end)
end
KeyEntry.load = t.wrap(KeyEntry.load, t.tuple(loadKeyEntryParamsCheck))

function KeyEntry:updateRecord(): Promise.TypedPromise<any>
	if self:isSaved() then
		return Promise.resolve()
	end

	local txInfo = { committedData = Dictionary.copyDeep(self.data) }

	return self:writeRecord(txInfo)
end
KeyEntry.updateRecord = t.wrap(KeyEntry.updateRecord, t.tuple(t.any))

function KeyEntry:writeRecord(txInfo: Types.TxInfo): Promise.TypedPromise<any>
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

	return FileManager.write(writeParams)
		:catch(function(err: FileManager.WriteError)
			self.ctx.log("error", `Failed to write shards for key {self.key}: {err.error}`)

			orphanFile(err.file)

			return Promise.reject(err.error)
		end)
		:andThen(function(file)
			local record = {
				version = self.version,
				file = file,
				orphanedFiles = Array.push(self.orphanedFiles, self.currentFile :: any),
			}

			if not self.lockHandle.isLocked() then
				orphanFile(file)
				return Promise.reject("KeyEntry lock was lost while writing record")
			end

			return self.ctx.dataStoreInterface
				:set(self.ctx.recordScope, self.key, record, self.userIds)
				:andThen(function()
					orphanFile(self.currentFile)
					self.currentFile = if FileManager.isLargeFile(file) then file else nil

					return record
				end)
				:catch(function(err)
					self.ctx.log("error", `Failed to write record for key {self.key}: {err}`)
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

function KeyEntry:mutateKey(newData: any): ()
	if self.closed then
		self.ctx.log("warn", `KeyEntry:mutateKey - Key {self.key} is closed, skipping mutation`)
		return
	end

	local oldData = if self.data then Dictionary.freezeDeep(self.data :: any) else nil

	local mutationId = HttpService:GenerateGUID(false)
	self.changeSet = Set.add(self.changeSet, mutationId)
	self.data = newData
	self.frozenData = Dictionary.freezeDeep(newData :: any)

	for _, callback in self.ctx.changedCallbacks do
		task.spawn(callback, self.key, self.frozenData, oldData)
	end
end
KeyEntry.mutateKey = t.wrap(KeyEntry.mutateKey, t.tuple(t.any, t.any))

function KeyEntry:startAutosaving(): ()
	if self._cleanupAutosave then
		self.ctx.log("warn", `KeyEntry:startAutosaving - Autosave already running for key {self.key}`)
		return
	end
	if self.closed then
		self.ctx.log("warn", `KeyEntry:startAutosaving - KeyEntry is closed, not starting autosave for key {self.key}`)
		return
	end

	local autosaveThread = task.spawn(function()
		while true do
			task.wait(Constants.AUTOSAVE_INTERVAL_SECONDS)
			if self.closed then
				break
			end

			local ok, err = self:save():await()
			if not ok then
				self.ctx.log("warn", `KeyEntry:startAutosaving - Failed to autosave key {self.key}: {err}`)
			end
		end
	end)

	local disconnectOnLockLost = self.lockHandle.onLockLost(function()
		self:stopAutosaving()
	end)

	self._cleanupAutosave = function()
		task.cancel(autosaveThread)
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
	if self.unloadPromise then
		return self.unloadPromise
	end

	self.closed = true
	self:stopAutosaving()

	self.unloadPromise = self.queue
		:add(function()
			return self:updateRecord()
		end)
		:finally(function()
			self.ctx.log("info", `KeyEntry:unload - Unloaded key {self.key}. Calling release`)
			return self.lockHandle.release():catch(function(e)
				self.ctx.log("warn", `KeyEntry:unload - Failed to release lock for key {self.key}: {e}`)
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
	if self.closed then
		return Promise.reject("KeyEntry is closed")
	end

	return Promise.new(function(resolve, reject)
		while self.txLockPromise ~= nil do
			self.txLockPromise:await()
		end

		local currentData = self.data
		local nextData = Dictionary.copyDeep(currentData)

		local transformOk, result = pcall(noYield, transformFunction, nextData :: any)
		if not transformOk then
			self.ctx.log("error", `KeyEntry:update - Transform function for key {self.key} failed: {result}`)
			return reject(`transformFunction failed: {result}`)
		end
		if typeof(result) ~= "boolean" then
			return reject("transformFunction must return a boolean")
		end

		if result == false then
			return resolve()
		end

		-- We deep copy here to prevent references to internal state from being
		-- leaked. If we didn't, the transform function could modify the state
		-- after it runs, which shouldn't be allowed.
		nextData = Dictionary.copyDeep(nextData)

		local schemaOk, err = self.ctx.schema(nextData :: any)
		if not schemaOk then
			self.ctx.log("error", `KeyEntry:update - Schema validation failed for key {self.key}: {err}`)
			return reject(`Store:update schema validation failed: {err}`)
		end

		if Dictionary.equalsDeep(nextData :: any, currentData :: any) then
			return resolve()
		end

		self:mutateKey(nextData)

		return resolve()
	end)
end
KeyEntry.update = t.wrap(KeyEntry.update, t.tuple(t.any, t.callback))

function KeyEntry:save(): Promise.Promise
	self.ctx.log("trace", `KeyEntry:save - start, key={self.key}`)
	if self.closed then
		self.ctx.log("warn", `KeyEntry:save - KeyEntry is closed, skipping save for key {self.key}`)
		return Promise.reject("KeyEntry is closed")
	end
	if self:isSaved() then
		self.ctx.log("trace", `KeyEntry:save - no changes, key={self.key}`)
		return Promise.resolve()
	end

	local changes = Set.copy(self.changeSet)

	self.ctx.log("trace", `KeyEntry:save - adding save to queue for key {self.key}`)
	return self.queue:add(function()
		self.ctx.log("trace", `KeyEntry:save - saving key {self.key}`)
		local changesWereSaved = Set.count(Set.intersection(changes, self.changeSet)) == 0
		if changesWereSaved then
			self.ctx.log("trace", `KeyEntry:save - changes were saved by another task, key={self.key}`)
			return Promise.resolve()
		end

		changes = Set.copy(self.changeSet)

		self.ctx.log(
			"trace",
			`KeyEntry:save - saving changes for key {self.key}, changes={HttpService:JSONEncode(changes)}`
		)
		return self:updateRecord():andThen(function()
			local newChangeSet = Set.difference(self.changeSet, changes)
			self.ctx.log(
				"trace",
				`KeyEntry:save - changes saved for key {self.key}, latestChanges={HttpService:JSONEncode(self.changeSet)} new changes={HttpService:JSONEncode(
					newChangeSet
				)}`
			)
			self.changeSet = newChangeSet
		end)
	end)
end
KeyEntry.save = t.wrap(KeyEntry.save, t.tuple(t.any))

return KeyEntry
