--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataStoreInterface = require(script.Parent.DataStoreInterface)
local Types = require(script.Parent.Types)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

local Dictionary = Sift.Dictionary

export type MigrateDataParams = {
	fromVersion: number,
	toVersion: number,
	data: any,
	migrations: { (data: any) -> any },
}

local function migrateData(params: MigrateDataParams): Promise.TypedPromise<any>
	local data = Dictionary.copyDeep(params.data)

	return Promise.new(function(resolve, reject)
		for i = params.fromVersion + 1, params.toVersion do
			local migration = params.migrations[i]
			if not migration then
				return reject(`No migration found for version {i}`)
			end

			local resolved, result = Promise.try(migration, data):await()
			if not resolved then
				return reject(`Migration failed for version {i}: {result}`)
			end

			data = Dictionary.copyDeep(result)
		end

		resolve(data)
	end)
end

export type LockHandle = {
	release: () -> Promise.Promise,
	isLocked: () -> boolean,
	onLockLost: (() -> ()) -> () -> (),
}

export type AcquireLockParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
	acquireAttempts: number,
	duration: number,
	refreshInterval: number,
}

local function acquireLock(params: AcquireLockParams): Promise.TypedPromise<LockHandle>
	local ctx = params.storeContext
	local key = params.key
	local scope = ctx.lockScope

	local lockId = HttpService:GenerateGUID(false)
	local lockExpiryThread: thread? = nil
	local lockRefreshThread: thread
	local locked = false
	local onLockLostCallbacks: { () -> () } = {}

	local function release(): Promise.Promise
		if lockRefreshThread then
			task.cancel(lockRefreshThread)
		end
		if lockExpiryThread then
			task.cancel(lockExpiryThread)
		end

		local function transformFunction(curLockId: string?): string?
			if curLockId == nil or curLockId == lockId then
				return ""
			end
			return nil
		end

		return ctx.hashMapInterface:update(scope, key, transformFunction, 0):finally(function()
			locked = false
		end)
	end

	local function lock()
		local function transformFunction(otherLockId: string?): string?
			if otherLockId == nil or otherLockId == lockId then
				return lockId
			end

			return nil
		end

		return Promise.new(function(resolve, reject, onCancel)
			onCancel(release)

			for i = 1, params.acquireAttempts do
				local resolved, lastValue =
					ctx.hashMapInterface:update(scope, key, transformFunction, params.duration):await()

				if resolved and lastValue ~= nil then
					return resolve()
				end

				if i ~= params.acquireAttempts then
					local retryAfter = math.min(2 ^ (i - 1), 30)
					task.wait(retryAfter)
				end
			end

			ctx.log("error", `Failed to acquire lock for key {key} after {params.acquireAttempts} attempts`)
			return reject("Failed to acquire lock")
		end):tap(function()
			if lockExpiryThread then
				task.cancel(lockExpiryThread)
			end

			lockExpiryThread = task.delay(params.duration, function()
				ctx.log("warn", `Lock for key {key} expired`)
				locked = false
				task.cancel(lockRefreshThread)
				for _, callback in onLockLostCallbacks do
					task.spawn(callback)
				end
			end)

			locked = true
		end)
	end

	local function lockRefreshLoop()
		while true do
			task.wait(params.refreshInterval)

			local resolved, err = lock():await()

			if not resolved then
				ctx.log("warn", `Failed to refresh lock for key {key}: {err}`)
			end
		end
	end

	local function isLocked(): boolean
		return locked
	end

	local function onLockLost(callback: () -> ()): () -> ()
		table.insert(onLockLostCallbacks, callback)
		return function()
			local idx = table.find(onLockLostCallbacks, callback)
			if idx then
				table.remove(onLockLostCallbacks, idx)
			end
		end
	end

	local handle: LockHandle = {
		release = release,
		isLocked = isLocked,
		onLockLost = onLockLost,
	}

	return lock():andThen(function()
		lockRefreshThread = task.spawn(lockRefreshLoop)
		return handle
	end)
end

export type ReadTxParams = {
	dataStoreInterface: DataStoreInterface.DataStoreInterface,
	scope: string,
	txInfo: Types.TxInfo,
}

local function readTx(params: ReadTxParams): Promise.TypedPromise<any>
	local txInfo = params.txInfo

	local txId = txInfo.txId
	if txId == nil then
		return Promise.resolve(txInfo.committedData)
	end

	return params.dataStoreInterface:get(params.scope, txId):andThen(function(committed)
		-- To save on storage space, we consider a tx to be committed if its
		-- value is `nil`. Failed or in-progress txs are stored as `false`.
		if committed == nil then
			return txInfo.txData
		else
			return txInfo.committedData
		end
	end)
end

return {
	acquireLock = acquireLock,
	migrateData = migrateData,
	readTx = readTx,
}
