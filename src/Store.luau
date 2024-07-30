--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Constants)
local DataStoreInterface = require(script.Parent.DataStoreInterface)
local HashMapInterface = require(script.Parent.HashMapInterface)
local KeyEntry = require(script.Parent.KeyEntry)
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
	migrateFromOtherSystem: ((key: string) -> T?)?,
	dataStoreInterface: DataStoreInterface.DataStoreInterface?,
	useMock: boolean?,
	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () -> () }?,
	logCallback: ((logMessage: Types.LogMessage) -> ())?,
	stopOutput: boolean?,
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
	stopOutput = t.optional(t.boolean),
})

type StoreImpl<T> = {
	__index: StoreImpl<T>,

	_processOrphanedFile: (self: Store<T>, item: Types.OrphanedFileQueueItem) -> boolean,

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
	_keyEntries: { [string]: KeyEntry.KeyEntry<T> },
	_lastTxId: string?,
	_unloadPromises: { [string]: Promise.Promise },
}

export type Store<T> = typeof(setmetatable({} :: StoreProps<T>, {} :: StoreImpl<T>))

local Store: StoreImpl<any> = {} :: StoreImpl<any>
Store.__index = Store

local function createStore<T>(config: StoreConfig<T>): Store<T>
	local function log(level: "fatal" | "error" | "warn" | "info" | "debug" | "trace", message: string)
		if not config.stopOutput then
			Log[level](message)
		end

		if config.logCallback ~= nil then
			config.logCallback({
				level = level,
				message = message,
			})
		end
	end

	log("info", `Creating new Store with name {config.name}`)
	local dataStoreInterface = config.dataStoreInterface
	if dataStoreInterface == nil then
		local service
		if config.useMock then
			assert(RunService:IsStudio(), "useMock can only be true in Studio")
			log("info", `Creating Store {config.name} with a mock DataStoreService`)
			service = (MockDataStoreService.createMockService() :: any) :: DataStoreService
		else
			log("trace", `Creating Store {config.name} with the real DataStoreService`)
			service = DataStoreService
		end

		dataStoreInterface = DataStoreInterface.new(service)
	end
	assert(dataStoreInterface, "luau")

	local hashMapInterface = HashMapInterface.new(MemoryStoreService)

	local orphanedFileQueue = OrphanedFileQueue.new()

	local migrations = config.migrations or {}
	log("trace", `Store {config.name} has {#migrations} migrations configured`)

	local storeContext: Types.StoreContext<T> = {
		name = config.name,
		template = config.template,
		schema = config.schema,
		migrations = migrations,
		migrateFromOtherSystem = config.migrateFromOtherSystem,
		dataStoreInterface = dataStoreInterface,
		hashMapInterface = hashMapInterface,
		lockId = HttpService:GenerateGUID(false),
		orphanedFileQueue = orphanedFileQueue,
		latestVersion = #migrations,
		changedCallbacks = config.changedCallbacks or {},
		log = log,
	}

	local ok, err = storeContext.schema(storeContext.template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	local self = setmetatable({
		_ctx = storeContext,
		_closed = false,
		_keyEntries = {},
		_lastTxId = nil,
		_unloadPromises = {},
	}, Store)

	orphanedFileQueue.processQueueItem = function(item)
		return self:_processOrphanedFile(item)
	end

	log("trace", `Store {config.name} created successfully`)
	return self
end
createStore = t.wrap(createStore, t.tuple(storeConfigCheck))

function Store:_processOrphanedFile(item: Types.OrphanedFileQueueItem): boolean
	self._ctx.log("trace", `Store {self._ctx.name}: Attempting to process orphaned file for key {item.key}`)
	local minBudget = 100
	local curBudget =
		self._ctx.dataStoreInterface:getRequestBudgetForBudgetType(Enum.DataStoreRequestType.SetIncrementAsync)
	if curBudget < minBudget then
		self._ctx.log(
			"debug",
			`Store {self._ctx.name}: Insufficient budget to process orphaned file for key {item.key}. Current budget: {curBudget}, minimum required: {minBudget}`
		)
		return false
	end

	self._ctx.log("debug", `Store {self._ctx.name}: Processing orphaned file for key {item.key}`)
	item.beingProcessed = true

	local promises = {}
	for i = 1, item.file.count do
		self._ctx.log(
			"trace",
			`Store {self._ctx.name}: Removing shard {i} of {item.file.count} for orphaned file {item.file.shard} for key {item.key}`
		)
		table.insert(promises, self._ctx.dataStoreInterface:remove(Constants.SHARD_SCOPE, `{item.file.shard}-{i}`))
	end

	Promise.all(promises)
		:andThen(function()
			self._ctx.log(
				"trace",
				`Store {self._ctx.name}: Successfully removed shards for orphaned file {item.file.shard} for key {item.key}`
			)
			local keyEntry = self._keyEntries[item.key]
			if keyEntry then
				keyEntry.orphanedFiles = Array.filter(keyEntry.orphanedFiles, function(file)
					return not Dictionary.equals(file, item.file)
				end)
			else
				self._ctx.log(
					"warn",
					`Store {self._ctx.name}: KeyEntry for {item.key} not found while processing orphaned file. This is a bug.`
				)
			end
		end)
		:catch(function(err)
			self._ctx.log(
				"error",
				`Store {self._ctx.name}: Failed to process orphaned file {item.file.shard} for key {item.key}: {err}`
			)
		end)
		:finally(function()
			self._ctx.log("trace", `Store {self._ctx.name}: Finished processing orphaned file for key {item.key}`)
			item.beingProcessed = false
		end)

	return true
end

function Store:load(key: string, userIds: { number }?): Promise.Promise
	self._ctx.log("trace", `Store {self._ctx.name}: Attempting to load key {key}`)
	if self._closed then
		self._ctx.log("warn", `Store {self._ctx.name}: Attempted to load key {key} while store is closed`)
		return Promise.reject("Store is closed")
	end

	return (self._unloadPromises[key] :: any or Promise.resolve()):finally(function()
		local keyEntry = KeyEntry.new({
			key = key,
			storeContext = self._ctx,
			userIds = userIds,
		})
		self._keyEntries[key] = keyEntry
		self._ctx.log("trace", `Store {self._ctx.name}: Loading key {key}`)
		return keyEntry:load()
	end)
end
Store.load = t.wrap(Store.load, t.tuple(t.any, t.string, t.optional(t.array(t.number))))

function Store:unload(key: string): Promise.Promise
	self._ctx.log("trace", `Store {self._ctx.name}: Attempting to unload key {key}`)
	if self._closed then
		self._ctx.log("warn", `Store {self._ctx.name}: Attempted to unload key {key} while store is closed`)
		return Promise.reject("Store is closed")
	end
	if self._unloadPromises[key] then
		self._ctx.log("trace", `Store {self._ctx.name}: Unload for key {key} is already in progress`)
		return Promise.reject("Unload already in progress")
	end

	self._ctx.log("trace", `Store {self._ctx.name}: Unloading key {key}`)
	self._unloadPromises[key] = self._keyEntries[key]:unload():tap(function()
		self._keyEntries[key] = nil
		self._unloadPromises[key] = nil
		self._ctx.log("trace", `Store {self._ctx.name}: Key {key} unloaded successfully`)
	end)

	return self._unloadPromises[key]
end
Store.unload = t.wrap(Store.unload, t.tuple(t.any, t.string))

function Store:get<T>(key: string): Promise.TypedPromise<T>
	self._ctx.log("trace", `Store {self._ctx.name}: Getting data for key {key}`)
	if self._closed then
		self._ctx.log("warn", `Store {self._ctx.name}: Attempted to get data for key {key} while store is closed`)
		return Promise.reject("Store is closed")
	end
	return self._keyEntries[key]:get()
end
Store.get = t.wrap(Store.get, t.tuple(t.any, t.string))

function Store:update<T>(key: string, transformFunction: (data: T) -> boolean): Promise.Promise
	self._ctx.log("trace", `Store {self._ctx.name}: Updating data for key {key}`)
	if self._closed then
		self._ctx.log("warn", `Store {self._ctx.name}: Attempted to update data for key {key} while store is closed`)
		return Promise.reject("Store is closed")
	end
	return self._keyEntries[key]:update(transformFunction)
end
Store.update = t.wrap(Store.update, t.tuple(t.any, t.string, t.callback))

function Store:tx<T>(keys: { string }, transformFunction: (state: { [string]: T }) -> boolean): Promise.Promise
	self._ctx.log("trace", `Store {self._ctx.name}: Beginning transaction for keys {table.concat(keys, ", ")}`)
	if self._closed then
		self._ctx.log(
			"warn",
			`Store {self._ctx.name}: Attempted to start transaction for keys {table.concat(keys, ", ")} while store is closed`
		)
		return Promise.reject("Store is closed")
	end

	local txLockResolve
	local txLockPromise = Promise.new(function(resolve)
		txLockResolve = resolve
	end)

	local isClosed = false
	local isLoaded = true
	local queues = Array.map(keys, function(key)
		local keyEntry = self._keyEntries[key]

		if keyEntry.closed then
			isClosed = true
		end
		if not keyEntry.loaded then
			isLoaded = false
		end

		return keyEntry.queue
	end)

	if isClosed then
		self._ctx.log(
			"error",
			`Store {self._ctx.name}: Cannot start transaction for keys {table.concat(keys, ", ")}: one or more KeyEntries are closed`
		)
		return Promise.reject("One or more KeyEntries are closed")
	end

	if not isLoaded then
		self._ctx.log(
			"error",
			`Store {self._ctx.name}: Cannot start transaction for keys {table.concat(keys, ", ")}: one or more KeyEntries are not loaded`
		)
		return Promise.reject("One or more KeyEntries are not loaded")
	end

	self._ctx.log("trace", `Store {self._ctx.name}: Acquiring transaction lock for keys {table.concat(keys, ", ")}`)
	return PromiseQueue.multiQueueAdd(queues, function()
		local currentState = {}
		for _, key in keys do
			local keyEntry = self._keyEntries[key]

			keyEntry.txLockPromise = txLockPromise
			currentState[key] = keyEntry.data
		end
		self._ctx.log("trace", `Store {self._ctx.name}: Acquired transaction lock for keys {table.concat(keys, ", ")}`)

		local nextState = Dictionary.copyDeep(currentState)
		local transformOk, result = pcall(noYield, transformFunction, nextState :: any)
		if not transformOk then
			self._ctx.log("error", `Store {self._ctx.name}: Transaction transform function failed: {result}`)
			error(`Store:tx transformFunction failed: {result}`)
		end

		assert(typeof(result) == "boolean", "Transaction transform function must return a boolean")

		if result == false then
			self._ctx.log(
				"trace",
				`Store {self._ctx.name}: Transaction transform function for keys {table.concat(keys, ", ")} returned false, skipping update`
			)
			return
		end

		-- We deep copy here to prevent references to internal state from being
		-- leaked. If we didn't, the transform function could modify the state
		-- after it runs, which shouldn't be allowed.
		nextState = Dictionary.copyDeep(nextState)

		for _, key in keys do
			local schemaOk, err = self._ctx.schema(nextState[key] :: any)
			if not schemaOk then
				self._ctx.log(
					"error",
					`Store {self._ctx.name}: Schema validation failed for key {key} during transaction: {err}`
				)
				error(`Store:tx schema validation failed: {err}`)
			end
		end

		local currentKeys = Dictionary.keys(currentState)
		local nextKeys = Dictionary.keys(nextState)
		assert(#Array.differenceSymmetric(currentKeys, nextKeys) == 0, "Keys changed in transaction")

		-- If no keys changed we can exit early, and if only one key changed, we
		-- can treat it as a normal :update.
		local changedKeys = Array.filter(keys, function(key)
			return not Dictionary.equalsDeep(currentState[key] :: any, nextState[key] :: any)
		end)

		if #changedKeys == 0 then
			self._ctx.log(
				"trace",
				`Store {self._ctx.name}: Transaction for keys {table.concat(keys, ", ")} resulted in no changes, skipping update`
			)
			return
		elseif #changedKeys == 1 then
			local key = changedKeys[1]
			self._ctx.log(
				"trace",
				`Store {self._ctx.name}: Transaction for keys {table.concat(keys, ", ")} only changed one key, treating as normal update`
			)
			self._keyEntries[key]:mutateKey(nextState[key])
			return
		end

		self._ctx.log(
			"debug",
			`Store {self._ctx.name}: Transaction for keys {table.concat(keys, ", ")} changed multiple keys, beginning multi-key update`
		)
		self._lastTxId = HttpService:GenerateGUID(false)
		local txId = self._lastTxId :: string

		local promises = Array.map(keys, function(key)
			local txInfo = {
				txId = txId,
				committedData = currentState[key],
				txData = nextState[key],
			}

			self._ctx.log("trace", `Store {self._ctx.name}: Writing record for key {key} in transaction {txId}`)
			return self._keyEntries[key]:writeRecord(txInfo)
		end)

		local commitPromise = Promise.all(promises)
			:andThen(function()
				self._ctx.log("trace", `Store {self._ctx.name}: Committing transaction {txId}`)
				return self._ctx.dataStoreInterface:set(Constants.TX_SCOPE, txId, true)
			end)
			:andThen(function()
				self._ctx.log("debug", `Store {self._ctx.name}: Transaction {txId} committed successfully`)
				for _, key in keys do
					-- :tx is required to save, so we commit all unsaved
					-- mutations here
					local keyEntry = self._keyEntries[key]
					keyEntry.changeSet = {}
					keyEntry.data = nextState[key]
				end
			end)
			:catch(function(err)
				self._ctx.log("error", `Store {self._ctx.name}: Transaction {txId} failed: {err}`)
				self._ctx.dataStoreInterface:set(Constants.TX_SCOPE, txId, false):catch(function(_abortErr)
					self._ctx.log(
						"fatal",
						`Store {self._ctx.name}: Failed to mark transaction {txId} as aborted: {_abortErr}`
					)
				end)

				return Promise.reject(err)
			end)
		return commitPromise
	end):finally(function()
		self._ctx.log("trace", `Store {self._ctx.name}: Releasing transaction lock for keys {table.concat(keys, ", ")}`)
		for _, key in keys do
			local keyEntry = self._keyEntries[key]
			if keyEntry.txLockPromise == txLockPromise then
				keyEntry.txLockPromise = nil :: any
			end
		end
		txLockResolve()
	end)
end
Store.tx = t.wrap(Store.tx, t.tuple(t.any, t.array(t.string), t.callback))

function Store:save(key: string): Promise.Promise
	self._ctx.log("trace", `Store {self._ctx.name}: Saving key {key}`)
	if self._closed then
		self._ctx.log("warn", `Store {self._ctx.name}: Attempted to save key {key} while store is closed`)
		return Promise.reject("Store is closed")
	end
	return self._keyEntries[key]:save()
end
Store.save = t.wrap(Store.save, t.tuple(t.any, t.string))

function Store:close(): Promise.Promise
	self._ctx.log("info", `Store {self._ctx.name}: Closing store`)
	local promises = {}
	for key in self._keyEntries do
		if self._unloadPromises[key] then
			self._ctx.log(
				"trace",
				`Store {self._ctx.name}: Key {key} is currently being unloaded, adding unload promise to closing sequence`
			)
			table.insert(promises, self._unloadPromises[key])
		else
			self._ctx.log("trace", `Store {self._ctx.name}: Key {key} is loaded, unloading as part of closing sequence`)
			table.insert(promises, self:unload(key))
		end
	end

	self._closed = true
	self._ctx.log("trace", `Store {self._ctx.name}: Store marked as closed`)

	return Promise.allSettled(promises):andThen(function()
		self._ctx.log("info", `Store {self._ctx.name}: Store closed successfully`)
	end)
end

return {
	createStore = createStore,
}
