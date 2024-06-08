--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Constants)
local DataStoreInterface = require(script.Parent.DataStoreInterface)
local KeyEntry = require(script.Parent.KeyEntry)
local MockDataStoreService = require(script.Parent.MockDataStoreService)
local OrphanedFileQueue = require(script.Parent.OrphanedFileQueue)
local PromiseQueue = require(script.Parent.PromiseQueue)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local t = require(ReplicatedStorage.Packages.t)
local Types = require(script.Parent.Types)
local noYield = require(script.Parent.noYield)

export type StoreConfig = {
	name: string,
	template: any,
	schema: (value: any) -> (boolean, string?),
	migrations: { [number]: (value: any) -> any }?,
	migrateFromOtherSystem: ((key: string) -> any?)?,
	dataStoreInterface: DataStoreInterface.DataStoreInterface?,
	useMock: boolean?,
}
local storeConfigCheck = t.strictInterface({
	name = t.string,
	template = t.any,
	schema = t.callback,
	migrations = t.optional(t.array(t.callback)),
	dataStoreInterface = t.optional(t.table),
	useMock = t.optional(t.boolean),
})

type StoreImpl = {
	__index: StoreImpl,

	_processOrphanedFile: (self: Store, item: Types.OrphanedFileQueueItem) -> boolean,

	lock: (self: Store, key: string) -> Promise.Promise,
	unlock: (self: Store, key: string) -> Promise.Promise,
	get: (self: Store, key: string) -> Promise.TypedPromise<any>,
	update: (self: Store, key: string, transformFunction: (data: any) -> any) -> Promise.Promise,
	tx: (
		self: Store,
		keys: { string },
		transformFunction: (state: { [string]: any }) -> { [string]: any }?
	) -> Promise.Promise,
	save: (self: Store, key: string) -> Promise.Promise,
}

type StoreProps = {
	_ctx: Types.StoreContext,
	_keyEntries: { [string]: KeyEntry.KeyEntry },
	_lastTxId: string?,
	_fileCleanupQueue: { { key: string, file: Types.File, beingProcessed: boolean } },
}

export type Store = typeof(setmetatable({} :: StoreProps, {} :: StoreImpl))

local Store: StoreImpl = {} :: StoreImpl
Store.__index = Store

local function createStore(config: StoreConfig): Store
	local dataStoreInterface = config.dataStoreInterface
	if dataStoreInterface == nil then
		local service
		if config.useMock then
			assert(RunService:IsStudio(), "useMock can only be true in Studio")
			service = (MockDataStoreService.createMockService() :: any) :: DataStoreService
		else
			service = DataStoreService
		end

		dataStoreInterface = DataStoreInterface.new(service)
	end
	assert(dataStoreInterface, "luau")

	local orphanedFileQueue = OrphanedFileQueue.new()

	local migrations = config.migrations or {}

	local storeContext: Types.StoreContext = {
		name = config.name,
		template = config.template,
		schema = config.schema,
		migrations = migrations,
		migrateFromOtherSystem = config.migrateFromOtherSystem,
		dataStoreInterface = dataStoreInterface,
		lockId = HttpService:GenerateGUID(false),
		orphanedFileQueue = orphanedFileQueue,
		latestVersion = math.max(#migrations, 1),
	}

	local ok, err = storeContext.schema(storeContext.template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	local self = setmetatable({
		_ctx = storeContext,
		_keyEntries = {},
		_lastTxId = nil,
		_fileCleanupQueue = {},
	}, Store)

	orphanedFileQueue.processQueueItem = function(item)
		return self:_processOrphanedFile(item)
	end

	return self
end
createStore = t.wrap(createStore, t.tuple(storeConfigCheck))

function Store:_processOrphanedFile(item: Types.OrphanedFileQueueItem): boolean
	local minBudget = 100
	local curBudget =
		self._ctx.dataStoreInterface:getRequestBudgetForBudgetType(Enum.DataStoreRequestType.SetIncrementAsync)
	if curBudget < minBudget then
		return false
	end

	item.beingProcessed = true

	local promises = {}
	for i = 1, item.file.count do
		table.insert(promises, self._ctx.dataStoreInterface:remove(Constants.SHARD_SCOPE, `{item.file.shard}-{i}`))
	end

	Promise.all(promises)
		:andThen(function()
			local keyEntry = self._keyEntries[item.key]
			keyEntry.orphanedFiles = Sift.Array.filter(keyEntry.orphanedFiles, function(file)
				return not Sift.Dictionary.equals(file, item.file)
			end)
		end)
		:finally(function()
			item.beingProcessed = false
		end)

	return true
end

function Store:lock(key: string, userIds: { number }?): Promise.Promise
	local keyEntry = KeyEntry.new({
		key = key,
		storeContext = self._ctx,
		userIds = userIds,
	})
	self._keyEntries[key] = keyEntry
	return keyEntry:lock()
end
Store.lock = t.wrap(Store.lock, t.tuple(t.any, t.string, t.optional(t.array(t.number))))

function Store:unlock(key: string): Promise.Promise
	return self._keyEntries[key]:unlock():tap(function()
		self._keyEntries[key] = nil
	end)
end
Store.unlock = t.wrap(Store.unlock, t.tuple(t.any, t.string))

function Store:get(key: string): Promise.Promise
	return self._keyEntries[key]:get()
end
Store.get = t.wrap(Store.get, t.tuple(t.any, t.string))

function Store:update(key: string, transformFunction: (data: any) -> any): Promise.Promise
	return self._keyEntries[key]:update(transformFunction)
end
Store.update = t.wrap(Store.update, t.tuple(t.any, t.string, t.callback))

function Store:tx(
	keys: { string },
	transformFunction: (state: { [string]: any }) -> { [string]: any }?
): Promise.Promise
	local txLockResolve
	local txLockPromise = Promise.new(function(resolve)
		txLockResolve = resolve
	end)

	local isClosed = false
	local isLocked = true
	local queues = Sift.Array.map(keys, function(key)
		local keyEntry = self._keyEntries[key]

		if keyEntry.closed then
			isClosed = true
		end
		if not keyEntry.locked then
			isLocked = false
		end

		return keyEntry.queue
	end)

	if isClosed then
		return Promise.reject("One or more KeyEntries are closed")
	end

	if not isLocked then
		return Promise.reject("One or more KeyEntries are not locked")
	end

	return PromiseQueue.multiQueueAdd(queues, function()
		local currentState = {}
		for _, key in keys do
			local keyEntry = self._keyEntries[key]

			keyEntry.txLockPromise = txLockPromise
			currentState[key] = keyEntry.data
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
			local schemaOk, err = self._ctx.schema(nextState[key] :: any)
			if not schemaOk then
				error(`Store:tx schema validation failed: {err}`)
			end
		end

		local currentKeys = Sift.Dictionary.keys(currentState)
		local nextKeys = Sift.Dictionary.keys(nextState)
		assert(#Sift.Array.differenceSymmetric(currentKeys, nextKeys) == 0, "Keys changed in transaction")

		-- If no keys changed we can exit early, and if only one key changed, we
		-- can treat it as a normal :update.
		local changedKeys = Sift.Array.filter(keys, function(key)
			return not Sift.Dictionary.equalsDeep(currentState[key] :: any, nextState[key] :: any)
		end)

		if #changedKeys == 0 then
			return
		elseif #changedKeys == 1 then
			local key = changedKeys[1]
			self._keyEntries[key]:mutateKey(nextState[key])
			return
		end

		self._lastTxId = HttpService:GenerateGUID(false)
		local txId = self._lastTxId :: string

		local promises = Sift.Array.map(keys, function(key)
			local txInfo = {
				txId = txId,
				committedData = currentState[key],
				txData = nextState[key],
			}

			return self._keyEntries[key]:writeRecord(txInfo)
		end)

		local commitPromise = Promise.all(promises)
			:andThen(function()
				return self._ctx.dataStoreInterface:set(Constants.TX_SCOPE, txId, true)
			end)
			:andThen(function()
				for _, key in keys do
					-- :tx is required to save, so we commit all unsaved
					-- mutations here
					local keyEntry = self._keyEntries[key]
					local snapshot = keyEntry:getSnapshot()
					keyEntry:commitSnapshot(snapshot)
					keyEntry.data = nextState[key]
				end
			end)
			:catch(function(err)
				self._ctx.dataStoreInterface:set(Constants.TX_SCOPE, txId, false):catch(function(_abortErr)
					-- TODO: log this
				end)

				return Promise.reject(err)
			end)
		return commitPromise
	end):finally(function()
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
	return self._keyEntries[key]:save()
end
Store.save = t.wrap(Store.save, t.tuple(t.any, t.string))

return {
	createStore = createStore,
}
