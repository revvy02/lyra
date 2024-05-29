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

type UnsavedMutationsSnapshot = { [string]: boolean }
local unsavedMutationsSnapshotCheck = t.map(t.string, t.boolean)

local function isLargeFile(file: Types.File): boolean
	return file.shard ~= nil
end

type KeyEntryImpl = {
	__index: KeyEntryImpl,
	new: (config: KeyEntryConfig) -> KeyEntry,
	writeLargeFile: (
		self: KeyEntry,
		data: any,
		metadata: { [string]: any }?
	) -> Promise.TypedPromise<Types.File>,
	readLargeFile: (self: KeyEntry, file: Types.File) -> Promise.TypedPromise<any>,
	readTx: (self: KeyEntry, txInfo: Types.TxInfo) -> Promise.TypedPromise<any>,
	writeRecord: (self: KeyEntry, txInfo: Types.TxInfo, releaseLock: boolean?) -> Promise.TypedPromise<any>,
	getLock: (self: KeyEntry) -> Types.Lock,
	getSnapshot: (self: KeyEntry) -> UnsavedMutationsSnapshot,
	isSnapshotCommitted: (self: KeyEntry, snapshot: UnsavedMutationsSnapshot) -> boolean,
	commitSnapshot: (self: KeyEntry, snapshot: UnsavedMutationsSnapshot) -> (),
	isSaved: (self: KeyEntry) -> boolean,
	mutateKey: (self: KeyEntry, newData: any) -> (),
	migrateData: (self: KeyEntry, data: any) -> Promise.TypedPromise<any>,
	lock: (self: KeyEntry) -> Promise.Promise,
	unlock: (self: KeyEntry) -> Promise.Promise,
	update: (self: KeyEntry, transformFunction: (data: any) -> any) -> Promise.Promise,
	save: (self: KeyEntry) -> Promise.Promise,
}

type KeyEntryProps = {
	key: string,
	ctx: Types.StoreContext,
	userIds: { number }?,
	data: any?,
	metadata: { [string]: any }?,
	version: number,
	unsavedMutations: UnsavedMutationsSnapshot,
	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	queue: PromiseQueue.PromiseQueue,
	txLockPromise: Promise.Promise?,
	closed: boolean,
}

export type KeyEntry = typeof(setmetatable({} :: KeyEntryProps, {} :: KeyEntryImpl))

type KeyEntryConfig = {
	key: string,
	storeContext: Types.StoreContext,
	userIds: { number }?,
}

local KeyEntry: KeyEntryImpl = {} :: KeyEntryImpl
KeyEntry.__index = KeyEntry

function KeyEntry.new(config: KeyEntryConfig): KeyEntry
	return setmetatable({
		key = config.key,
		ctx = config.storeContext,
		userIds = config.userIds,
		data = nil,
		metadata = nil,
		version = config.storeContext.latestVersion,
		unsavedMutations = {},
		orphanedFiles = {},
		currentFile = nil,
		queue = PromiseQueue.new(),
		txLockPromise = nil,
		closed = false,
	}, KeyEntry)
end

function KeyEntry:writeLargeFile(data: any, metadata: { [string]: any }?): Promise.TypedPromise<Types.File>
	local str = HttpService:JSONEncode(data)
	if #str <= Constants.MAX_CHUNK_SIZE then
		return Promise.resolve({ data = data } :: Types.File)
	end

	local shardId = HttpService:GenerateGUID(false)
	local shards = splitUtf8String(data, Constants.MAX_CHUNK_SIZE)

	local promises = Sift.Array.map(shards, function(shard, index)
		return self.ctx.dataStoreInterface:set(
			Constants.SHARD_SCOPE,
			`{shardId}-{index}`,
			shard,
			self.userIds,
			metadata
		)
	end)

	local file = { shard = shardId, count = #shards }

	local p = Promise.all(promises):andThenReturn(file):catch(function(err)
		table.insert(self.orphanedFiles, file)
		self.ctx.orphanedFileQueue:markFile(self.key, file)
		return Promise.reject(err)
	end)

	return p
end
KeyEntry.writeLargeFile = t.wrap(KeyEntry.writeLargeFile, t.tuple(t.any, t.any, t.optional(t.map(t.string, t.any))))

function KeyEntry:readLargeFile(file: Types.File): Promise.TypedPromise<any>
	if not isLargeFile(file) then
		return Promise.resolve(file.data)
	end

	local shardId = file.shard
	local promises = {}

	for i = 1, file.count do
		table.insert(promises, self.ctx.dataStoreInterface:get(Constants.SHARD_SCOPE, `{shardId}-{i}`))
	end

	return Promise.all(promises):andThen(function(shards)
		return HttpService:JSONDecode(table.concat(shards))
	end)
end
KeyEntry.readLargeFile = t.wrap(KeyEntry.readLargeFile, t.tuple(t.any, Types.fileCheck))

function KeyEntry:readTx(txInfo: Types.TxInfo): Promise.TypedPromise<any>
	local txId = txInfo.txId
	if txId == nil then
		return Promise.resolve(txInfo.committedData)
	end

	return self.ctx.dataStoreInterface:get(Constants.TX_SCOPE, txId):andThen(function(committed)
		if committed == true then
			return txInfo.txData
		else
			return txInfo.committedData
		end
	end)
end
KeyEntry.readTx = t.wrap(KeyEntry.readTx, t.tuple(t.any, Types.txInfoCheck))

function KeyEntry:writeRecord(txInfo: Types.TxInfo, releaseLock: boolean?): Promise.TypedPromise<any>
	return self:writeLargeFile(txInfo):andThen(function(file)
		local orphanedFiles = Sift.Array.push(self.orphanedFiles, self.currentFile :: any)

		local record = {
			version = self.version,
			lock = if releaseLock then {} else self:getLock(),
			file = file,
			orphanedFiles = orphanedFiles,
		}
		local metadata = self.metadata

		return self.ctx.dataStoreInterface
			:update(Constants.RECORD_SCOPE, self.key, function(previousValue, keyInfo)
				if previousValue.lock.id ~= self.ctx.lockId then
					return nil :: any, keyInfo:GetUserIds(), keyInfo:GetMetadata()
				end

				return record, self.userIds, metadata
			end)
			:andThen(function(value)
				if releaseLock and value.lock.id ~= nil then
					return Promise.reject("Failed to release lock")
				elseif not releaseLock and value.lock.id ~= self.ctx.lockId then
					return Promise.reject("Lock violation")
				end

				self.orphanedFiles = orphanedFiles
				self.currentFile = if isLargeFile(file) then file else nil
				if self.currentFile then
					self.ctx.orphanedFileQueue:markFile(self.key, self.currentFile)
				end

				return value
			end)
			:catch(function(err)
				if isLargeFile(file) then
					self.orphanedFiles = Sift.Array.push(self.orphanedFiles, file)
					self.ctx.orphanedFileQueue:markFile(self.key, file)
				end

				return Promise.reject(err)
			end)
	end)
end
KeyEntry.writeRecord = t.wrap(KeyEntry.writeRecord, t.tuple(t.any, Types.txInfoCheck, t.optional(t.boolean)))

function KeyEntry:getLock(): Types.Lock
	return {
		id = self.ctx.lockId,
		expiry = DateTime.now().UnixTimestamp + Constants.LOCK_DURATION_SECONDS,
	}
end

function KeyEntry:getSnapshot(): UnsavedMutationsSnapshot
	return Sift.Set.copy(self.unsavedMutations)
end
KeyEntry.getSnapshot = t.wrap(KeyEntry.getSnapshot, t.tuple(t.any))

function KeyEntry:isSnapshotCommitted(snapshot: UnsavedMutationsSnapshot): boolean
	local intersection = Sift.Set.intersection(snapshot, self.unsavedMutations)
	return Sift.Set.count(intersection) == 0
end
KeyEntry.isSnapshotCommitted = t.wrap(KeyEntry.isSnapshotCommitted, t.tuple(t.any, unsavedMutationsSnapshotCheck))

function KeyEntry:commitSnapshot(snapshot: UnsavedMutationsSnapshot): ()
	self.unsavedMutations = Sift.Set.difference(self.unsavedMutations, snapshot)
end
KeyEntry.commitSnapshot = t.wrap(KeyEntry.commitSnapshot, t.tuple(t.any, unsavedMutationsSnapshotCheck))

function KeyEntry:isSaved(): boolean
	return Sift.Set.count(self.unsavedMutations) == 0
end
KeyEntry.isSaved = t.wrap(KeyEntry.isSaved, t.tuple(t.any))

function KeyEntry:mutateKey(newData: any): ()
	local mutationId = HttpService:GenerateGUID(false)
	self.unsavedMutations = Sift.Set.add(self.unsavedMutations, mutationId)
	self.data = newData
end
KeyEntry.mutateKey = t.wrap(KeyEntry.mutateKey, t.tuple(t.any, t.any))

function KeyEntry:migrateData(data: any): Promise.TypedPromise<any>
	return Promise.new(function(resolve)
		for i = self.version + 1, self.ctx.latestVersion do
			local migration = self.ctx.migrations[i]
			if migration then
				data = Promise.try(migration, data):expect()
			end
		end

		resolve(data)
	end)
end

function KeyEntry:lock(): Promise.Promise
	local function transformFunction(value, keyInfo)
		value = Sift.Dictionary.mergeDeep({ lock = {} }, value)

		local lock = value.lock
		if lock.expiry ~= nil and lock.expiry > DateTime.now().UnixTimestamp then
			-- TODO: retry after lock expiry
			return nil, keyInfo:GetUserIds(), keyInfo:GetMetadata()
		end

		value.lock = self:getLock()

		return value, self.userIds, keyInfo:GetMetadata()
	end

	return self.ctx.dataStoreInterface
		:update(Constants.RECORD_SCOPE, self.key, transformFunction)
		:andThen(function(record: Types.DataStoreRecord, _userIds, metadata)
			if record.lock.id ~= self.ctx.lockId then
				return Promise.reject("Failed to acquire lock")
			end

			self.metadata = metadata
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

				return self:readLargeFile(file)
			end

			return nil :: any
		end)
		:andThen(function(txInfo)
			return if txInfo then self:readTx(txInfo) else nil
		end)
		:andThen(function(data)
			if data == nil then
				data = Sift.Dictionary.copyDeep(self.ctx.template)
			end

			if self.version > self.ctx.latestVersion then
				return Promise.reject("Data has newer version than this server supports")
			elseif self.version < self.ctx.latestVersion then
				data = self:migrateData(data):expect()
				self.version = self.ctx.latestVersion
			end

			self.data = data

			return data
		end)
end
KeyEntry.lock = t.wrap(KeyEntry.lock, t.tuple(t.any))

function KeyEntry:unlock(): Promise.Promise
	if self.closed then
		return Promise.reject("KeyEntry is closed")
	end

	self.closed = true

	return self.queue:add(function()
		local data = Sift.Dictionary.copyDeep(self.data)
		local txInfo = { committedData = data }

		return self:writeRecord(txInfo, true):andThen(function(latestValue)
			self.ctx.orphanedFileQueue:markFiles(self.key, latestValue.orphanedFiles)
		end)
	end)
end
KeyEntry.unlock = t.wrap(KeyEntry.unlock, t.tuple(t.any))

function KeyEntry:update(transformFunction: (data: { [string]: any }) -> { [string]: any }): Promise.Promise
	if self.closed then
		return Promise.reject("KeyEntry is closed")
	end

	return Promise.new(function(resolve, reject)
		while self.txLockPromise ~= nil do
			self.txLockPromise:await()
		end

		local currentData = self.data
		local nextData = Sift.Dictionary.copyDeep(currentData)
		local transformOk, result = pcall(noYield, transformFunction, nextData)
		if not transformOk then
			return reject(`Store:update transformFunction failed: {result}`)
		end

		if result == nil then
			print(`Skipping update for key {self.key}`)
			return resolve()
		end
		nextData = result

		if Sift.Dictionary.equalsDeep(nextData :: any, currentData :: any) then
			return resolve()
		end

		local schemaOk, err = self.ctx.schema(nextData :: any)
		if not schemaOk then
			return reject(`Store:update schema validation failed: {err}`)
		end

		self:mutateKey(nextData)

		return resolve()
	end)
end
KeyEntry.update = t.wrap(KeyEntry.update, t.tuple(t.any, t.callback))

function KeyEntry:save(): Promise.Promise
	if self.closed then
		return Promise.reject("KeyEntry is closed")
	end

	if self:isSaved() then
		return Promise.resolve()
	end
	local snapshot = self:getSnapshot()

	return self.queue:add(function()
		if self:isSnapshotCommitted(snapshot) then
			return
		end

		if self:isSaved() then
			return
		end

		snapshot = self:getSnapshot()

		local data = Sift.Dictionary.copyDeep(self.data)
		local txInfo = { committedData = data }

		return self:writeRecord(txInfo):andThen(function()
			self:commitSnapshot(snapshot)
		end)
	end)
end
KeyEntry.save = t.wrap(KeyEntry.save, t.tuple(t.any))

return KeyEntry
