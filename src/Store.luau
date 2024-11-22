--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Constants)
local DataStoreInterface = require(script.Parent.DataStoreInterface)
local HashMapInterface = require(script.Parent.HashMapInterface)
local Session = require(script.Parent.Session)
local Log = require(script.Parent.Log)
local MockDataStoreService = require(script.Parent.MockDataStoreService)
local OrphanedFileQueue = require(script.Parent.OrphanedFileQueue)
local PromiseQueue = require(script.Parent.PromiseQueue)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local t = require(ReplicatedStorage.Packages.t)
local Types = require(script.Parent.Types)
local noYield = require(script.Parent.noYield)

local Dictionary = Sift.Dictionary
local Array = Sift.Array

export type StoreConfig<T> = {
	name: string,
	template: T,
	schema: (value: any) -> (boolean, string?),
	migrations: { [number]: (value: any) -> any }?,
	migrateFromOtherSystem: ((key: string) -> any?)?,
	dataStoreInterface: Types.DataStoreInterface?,
	useMock: boolean?,
	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () -> () }?,
	logCallback: ((logMessage: Types.LogMessage) -> ())?,
	onLockLost: ((key: string) -> ())?,
}
local storeConfigCheck = t.strictInterface({
	name = t.string,
	template = t.any,
	schema = t.callback,
	migrations = t.optional(t.array(t.callback)),
	migrateFromOtherSystem = t.optional(t.callback),
	dataStoreInterface = t.optional(t.table),
	useMock = t.optional(t.boolean),
	changedCallbacks = t.optional(t.array(t.callback)),
	logCallback = t.optional(t.callback),
	onLockLost = t.optional(t.callback),
})

type StoreImpl<T> = {
	__index: StoreImpl<T>,

	_processOrphanedFile: (self: Store<T>, item: Types.OrphanedFileQueueItem) -> boolean,
	_withSession: (self: Store<T>, key: string, callback: (session: Session.Session<any>) -> ()) -> Promise.Promise,
	_getKeyInfo: (self: Store<T>, key: string) -> Promise.TypedPromise<DataStoreKeyInfo?>,

	load: (self: Store<T>, key: string, userIds: { number }?) -> Promise.Promise,
	unload: (self: Store<T>, key: string) -> Promise.Promise,
	get: (self: Store<T>, key: string) -> Promise.TypedPromise<T>,
	update: (self: Store<T>, key: string, transformFunction: (data: T) -> boolean) -> Promise.Promise,
	tx: (
		self: Store<T>,
		keys: { string },
		transformFunction: (state: { [string]: T }) -> boolean
	) -> Promise.Promise,
	save: (self: Store<T>, key: string) -> Promise.Promise,
	close: (self: Store<T>) -> Promise.Promise,
}

type StoreProps<T> = {
	_ctx: Types.StoreContext<T>,
	_closed: boolean,
	_sessions: { [string]: Session.Session<T> },
	_lastTxId: string?,
	_loadPromises: { [string]: Promise.Promise },
	_unloadPromises: { [string]: Promise.Promise },
}

export type Store<T> = typeof(setmetatable({} :: StoreProps<T>, {} :: StoreImpl<T>))

local Store: StoreImpl<any> = {} :: StoreImpl<any>
Store.__index = Store

local function createStore<T>(config: StoreConfig<T>): Store<T>
	local logger = Log.createLogger(config.logCallback or function() end, {
		lib = "lyra",
		store = config.name,
	})

	logger:log("debug", `creating store`)
	local dataStoreInterface = config.dataStoreInterface
	if dataStoreInterface == nil then
		local service
		if config.useMock then
			assert(RunService:IsStudio(), "useMock can only be true in Studio")
			logger:log("info", `using mock DataStoreService`)
			service = (MockDataStoreService.createMockService() :: any) :: DataStoreService
		else
			logger:log("trace", `using real DataStoreService`)
			service = DataStoreService
		end

		dataStoreInterface = DataStoreInterface.new(service)
	end
	assert(dataStoreInterface, "luau")

	local hashMapInterface = HashMapInterface.new(MemoryStoreService)
	local orphanedFileQueue = OrphanedFileQueue.new()

	local migrations = config.migrations or {}

	local storeContext: Types.StoreContext<T> = {
		name = config.name,
		template = config.template,
		schema = config.schema,

		migrations = migrations,
		migrateFromOtherSystem = config.migrateFromOtherSystem,
		latestVersion = #migrations,

		dataStoreInterface = dataStoreInterface,
		hashMapInterface = hashMapInterface,

		orphanedFileQueue = orphanedFileQueue,
		changedCallbacks = config.changedCallbacks or {},
		logger = logger,
		onLockLost = config.onLockLost,

		recordScope = `{Constants.RECORD_SCOPE}/{config.name}`,
		shardScope = `{Constants.SHARD_SCOPE}/{config.name}`,
		txScope = `{Constants.TX_SCOPE}/{config.name}`,
		lockScope = `{Constants.LOCK_SCOPE}/{config.name}`,
	}

	local ok, err = storeContext.schema(storeContext.template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	local self = setmetatable({
		_ctx = storeContext,
		_closed = false,
		_sessions = {},
		_lastTxId = nil,
		_loadPromises = {},
		_unloadPromises = {},
	}, Store)

	orphanedFileQueue.processQueueItem = function(item)
		return self:_processOrphanedFile(item)
	end

	logger:log("trace", `created store`)
	return self
end
createStore = t.wrap(createStore, t.tuple(storeConfigCheck))

function Store:_processOrphanedFile(item: Types.OrphanedFileQueueItem): boolean
	local logger = self._ctx.logger:extend({ method = "_processOrphanedFile", key = item.key, shard = item.file.shard })

	local minBudget = 100
	local curBudget =
		self._ctx.dataStoreInterface:getRequestBudgetForBudgetType(Enum.DataStoreRequestType.SetIncrementAsync)
	if curBudget < minBudget then
		logger:log("debug", "insufficient budget", {
			curBudget = curBudget,
			minBudget = minBudget,
		})
		return false
	end

	logger:log("debug", "processing orphaned file")
	item.beingProcessed = true

	local promises = {}
	for i = 1, item.file.count do
		logger:log("trace", `Removing shard {i} of {item.file.count}`)
		table.insert(promises, self._ctx.dataStoreInterface:remove(Constants.SHARD_SCOPE, `{item.file.shard}-{i}`))
	end

	Promise.all(promises)
		:andThen(function()
			logger:log("trace", "successfully removed shards")
			local session = self._sessions[item.key]
			if session then
				session.orphanedFiles = Array.filter(session.orphanedFiles, function(file)
					return not Dictionary.equals(file, item.file)
				end)
			end
		end)
		:catch(function(err)
			logger:log("error", `failed to remove shards: {err}`)
		end)
		:finally(function()
			logger:log("trace", "finished processing orphaned file")
			item.beingProcessed = false
		end)

	return true
end

function Store:load(key: string, userIds: { number }?): Promise.Promise
	local logger = self._ctx.logger:extend({ method = "load", key = key })
	logger:log("trace", "attempting to load key")

	if self._closed then
		logger:log("warn", "attempted to load key while store is closed")
		return Promise.reject("Store is closed")
	end

	if self._sessions[key] and not self._unloadPromises[key] then
		logger:log("trace", "key is already loaded")
		return Promise.resolve()
	end

	if self._loadPromises[key] then
		logger:log("trace", "key is currently being loaded")
		return Promise.reject("Load already in progress")
	end

	local waitForUnload = Promise.try(function()
		local unloadPromise = self._unloadPromises[key]
		if unloadPromise then
			logger:log("trace", "waiting for unload to complete")
			unloadPromise:await()
		end
	end)

	local params = {
		storeContext = self._ctx,
		key = key,
		userIds = userIds,
	}
	local loadPromise = waitForUnload:andThenCall(Session.load, params):andThen(function(session)
		if self._closed then
			logger:log("warn", "store closed before key loaded")

			self._unloadPromises[key] = session:unload():finally(function()
				logger:log("trace", "key unloaded")
				self._unloadPromises[key] = nil
			end)

			return Promise.reject("Store closed before key loaded")
		end

		self._sessions[key] = session

		session:startAutosaving()
		session.lockHandle.onLockLost(function()
			if self._ctx.onLockLost then
				self._ctx.onLockLost(key)
			end
			self._sessions[key] = nil
		end)
	end)

	self._loadPromises[key] = loadPromise
	loadPromise:finally(function()
		self._loadPromises[key] = nil
	end)

	return loadPromise:finally(function(status)
		if status == (Promise :: any).Status.Cancelled then
			logger:log("trace", "load was cancelled")
			return Promise.reject("Load was cancelled")
		end
	end)
end
Store.load = t.wrap(Store.load, t.tuple(t.any, t.string, t.optional(t.array(t.number))))

function Store:unload(key: string): Promise.Promise
	local logger = self._ctx.logger:extend({ method = "unload", key = key })
	logger:log("trace", "attempting to unload key")

	if self._closed then
		logger:log("warn", "attempted to unload key while store is closed")
		return Promise.reject("Store is closed")
	end

	if self._loadPromises[key] then
		logger:log("trace", "key is being loaded, cancelling load")
		self._loadPromises[key]:cancel()
		return Promise.resolve()
	end

	if self._unloadPromises[key] then
		logger:log("trace", "key is being unloaded")
		return self._unloadPromises[key]
	end

	if not self._sessions[key] then
		logger:log("warn", "key not loaded")
		return Promise.resolve()
	end

	logger:log("trace", "unloading key")
	self._unloadPromises[key] = self._sessions[key]:unload():finally(function()
		logger:log("trace", "key unloaded")
		self._sessions[key] = nil
		self._unloadPromises[key] = nil
	end)

	return self._unloadPromises[key] or Promise.resolve()
end
Store.unload = t.wrap(Store.unload, t.tuple(t.any, t.string))

function Store:_withSession(key: string, callback: (session: Session.Session<any>) -> any): Promise.Promise
	local logger = self._ctx.logger:extend({ method = "_withSession", key = key })

	return Promise.new(function(resolve, reject)
		if self._closed then
			logger:log("warn", "attempted to use key while store is closed")
			return reject("Store is closed")
		end

		local loadPromise = self._loadPromises[key]
		if loadPromise then
			logger:log("trace", "key being loaded, waiting")
			local loaded = loadPromise:await()
			if not loaded then
				return loadPromise:finally(function(status)
					if status == (Promise :: any).Status.Cancelled then
						logger:log("trace", "load cancelled")
						return reject("Load was cancelled")
					end
				end)
			end
		end

		if self._unloadPromises[key] then
			logger:log("warn", "key is being unloaded")
		end

		local session = self._sessions[key]
		if not session then
			logger:log("warn", "key not loaded")
			return reject("Key not loaded")
		end

		resolve(callback(session))
	end)
end

function Store:_getKeyInfo(key: string): Promise.TypedPromise<DataStoreKeyInfo?>
	return self:_withSession(key, function(session)
		return session.keyInfo
	end)
end

function Store:get<T>(key: string): Promise.TypedPromise<T>
	return self:_withSession(key, function(session)
		return session:get()
	end)
end
Store.get = t.wrap(Store.get, t.tuple(t.any, t.string))

function Store:update<T>(key: string, transformFunction: (data: T) -> boolean): Promise.Promise
	return self:_withSession(key, function(session)
		return session:update(transformFunction)
	end)
end
Store.update = t.wrap(Store.update, t.tuple(t.any, t.string, t.callback))

function Store:tx<T>(keys: { string }, transformFunction: (state: { [string]: T }) -> boolean): Promise.Promise
	local txId = HttpService:GenerateGUID(false)
	local logger = self._ctx.logger:extend({ method = "tx", keys = keys, txId = txId })

	logger:log("trace", "starting transaction")
	if self._closed then
		logger:log("warn", "attempted to start transaction while store is closed")
		return Promise.reject("Store is closed")
	end

	for _, key in keys do
		local session = self._sessions[key]
		if not session then
			return Promise.reject(`Key {key} not loaded`)
		end
		if session.txLockPromise then
			return Promise.reject(`Key {key} is already locked by another transaction`)
		end
		if session.closed then
			return Promise.reject(`Key {key} is closed`)
		end
	end

	local txLockResolve
	local txLockPromise = Promise.new(function(resolve)
		txLockResolve = resolve
	end)

	local queues = Array.map(keys, function(key)
		return self._sessions[key].queue
	end)

	-- Normally we'd represent 'committed' as `true` and 'failed' as `false`.
	-- This leaves a dangling DataStore entry (TX_SCOPE, txId). To clean it up,
	-- we need to write all the keys again, committing their staged data and
	-- removing txId from them. If all those succeed, *then* we can remove the
	-- status entry. However, if we invert this so that 'committed' is `nil` and
	-- 'failed' is `false`, we get a neat bonus where committing the tx also
	-- cleans up what would be the dangling entry. Because `nil` means
	-- 'committed', we can just leave the keys alone, and remove the status
	-- entry. Assuming most transactions succeed, this saves a lot of writes.
	local txStatusPromise = self._ctx.dataStoreInterface:set(Constants.TX_SCOPE, txId, false)

	-- Session:update waits for txLockPromise to resolve if it exists. We only
	-- want to resolve it when the transaction logic has completely finished, so
	-- we use this helper function to wrap the transaction logic.
	local function withTxLock(fn: () -> Promise.Promise): Promise.Promise
		for _, key in keys do
			local session = self._sessions[key]
			session.txLockPromise = txLockPromise
		end
		logger:log("trace", "set txLockPromise on Sessions")

		return Promise.try(fn):finally(function()
			for _, key in keys do
				local session = self._sessions[key]
				if session.txLockPromise == txLockPromise then
					session.txLockPromise = nil :: any
				end
			end
			logger:log("trace", "cleared txLockPromise on Sessions")
			txLockResolve()
		end)
	end

	logger:log("trace", `acquiring PromiseQueue lock on keys`)
	return PromiseQueue.multiQueueAdd(queues, function()
		logger:log("trace", `acquired PromiseQueue lock on keys`)
		if txStatusPromise:awaitStatus() ~= (Promise :: any).Status.Resolved then
			logger:log("error", "failed to pre-set txId")
			return Promise.reject("Failed to pre-set tx")
		end

		return withTxLock(function()
			local currentState = {}
			for _, key in keys do
				local session = self._sessions[key]
				currentState[key] = session.data
			end

			local nextState = Dictionary.copyDeep(currentState)
			local transformOk, result = pcall(noYield, transformFunction, nextState :: any)
			if not transformOk then
				logger:log("error", "tx transformFunction failed", { error = result })
				return Promise.reject(`Store:tx transformFunction failed: {result}`)
			end

			assert(typeof(result) == "boolean", "Transaction transform function must return a boolean")

			if result == false then
				logger:log("trace", "tx transformFunction returned false, skipping update")
				return Promise.reject("Transaction transform function returned false")
			end

			-- We deep copy here to prevent references to internal state from being
			-- leaked. If we didn't, the transform function could modify the state
			-- after it runs, which shouldn't be allowed.
			nextState = Dictionary.copyDeep(nextState)

			for _, key in keys do
				local schemaOk, err = self._ctx.schema(nextState[key] :: any)
				if not schemaOk then
					logger:log("error", `schema validation for key {key} failed: {err}`)
					Promise.reject(`Store:tx schema validation failed: {err}`)
				end
			end

			local currentKeys = Dictionary.keys(currentState)
			local nextKeys = Dictionary.keys(nextState)
			if #Array.differenceSymmetric(currentKeys, nextKeys) ~= 0 then
				logger:log("error", "keys changed in transaction")
				return Promise.reject("Keys changed in transaction")
			end

			-- If no keys changed we can exit early, and if only one key changed, we
			-- can treat it as a normal :update.
			local changedKeys = Array.filter(keys, function(key)
				return not Dictionary.equalsDeep(currentState[key] :: any, nextState[key] :: any)
			end)

			if #changedKeys == 0 then
				logger:log("trace", "tx had no mutations, skipping update")
				return Promise.resolve()
			elseif #changedKeys == 1 then
				logger:log("trace", `tx only changed one key, treating as Session:update`)
				local key = changedKeys[1]
				self._sessions[key]:mutateKey(nextState[key])
				return Promise.resolve()
			end

			logger:log("trace", "tx changed multiple keys, beginning multi-key update")

			local keyWritePromises = Array.map(keys, function(key)
				local txInfo = {
					txId = txId,
					txData = nextState[key],
					committedData = currentState[key],
				}

				return self._sessions[key]:writeRecord(txInfo)
			end)

			local function revert(err)
				logger:log("error", "multi-key update or tx commit failed, reverting", { error = err })

				local cleanupPromises = Array.map(keys, function(key)
					local txInfo = { committedData = currentState[key] }
					return self._sessions[key]:writeRecord(txInfo)
				end)

				return Promise.all(cleanupPromises)
					:andThen(function()
						logger:log("trace", "multi-key update reverted, cleaning up tx status")
						return self._ctx.dataStoreInterface:remove(Constants.TX_SCOPE, txId)
					end)
					:andThen(function()
						logger:log("trace", "tx status cleaned up")
						return Promise.reject(err)
					end)
			end

			local updateAndCommitPromise = Promise.all(keyWritePromises)
				:andThen(function()
					logger:log("trace", "multi-key update successful, committing transaction")
					return self._ctx.dataStoreInterface:remove(Constants.TX_SCOPE, txId)
				end)
				:catch(revert)
				:andThen(function()
					logger:log("debug", "transaction committed successfully")

					-- We just technically performed a save, so let's
					-- reflect that in the Sessions.
					for _, key in keys do
						local session = self._sessions[key]
						session:setData(nextState[key])
						session.changeSet = {}
					end
				end)
				:finally(function()
					logger:log("trace", "tx finished")
				end)

			return updateAndCommitPromise
		end)
	end)
end
Store.tx = t.wrap(Store.tx, t.tuple(t.any, t.array(t.string), t.callback))

function Store:save(key: string): Promise.Promise
	return self:_withSession(key, function(session)
		return session:save()
	end)
end
Store.save = t.wrap(Store.save, t.tuple(t.any, t.string))

function Store:close(): Promise.Promise
	local logger = self._ctx.logger:extend({ method = "close" })
	logger:log("trace", "closing store")

	for _, loadPromise in self._loadPromises do
		(loadPromise :: any):cancel()
	end

	local promises = {}
	for key in self._sessions do
		if self._unloadPromises[key] then
			logger:log("trace", "key already being unloaded", { key = key })
			table.insert(promises, self._unloadPromises[key])
		else
			logger:log("trace", "unloading key", { key = key })
			table.insert(promises, self:unload(key))
		end
	end

	self._closed = true
	logger:log("trace", "store marked as closed")

	return Promise.allSettled(promises):andThen(function()
		logger:log("debug", "store closed")
	end)
end

return {
	createStore = createStore,
}
