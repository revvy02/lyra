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

local activeLocks = {}

local function acquireLock(params: AcquireLockParams): Promise.TypedPromise<LockHandle>
	local ctx = params.storeContext
	local key = params.key
	local scope = ctx.lockScope

	local lockId = HttpService:GenerateGUID(false)
	local lockExpiryThread: thread? = nil
	local refreshLock
	local locked = false
	local onLockLostCallbacks: { () -> () } = {}
	local curLockPromise: any

	local lastUpdate
	activeLocks[key] = activeLocks[key] or {}
	local lockCounter = 0
	local version = 0
	local releasing = false

	local function release(): Promise.Promise
		ctx.log("info", `store({ctx.name}) key({key}) lockId({lockId}) Release called`)
		if releasing then
			return Promise.resolve()
		end
		releasing = true
		refreshLock = false

		if curLockPromise then
			curLockPromise:cancel()
		end

		if lockExpiryThread then
			lockCounter -= 1
			task.cancel(lockExpiryThread)
			lockExpiryThread = nil
		end

		local function transformFunction(curLockId: string?): string?
			if curLockId == nil or curLockId == lockId then
				return ""
			end
			return nil
		end

		return ctx.hashMapInterface:update(scope, key, transformFunction, 0):finally(function()
			table.remove(activeLocks[key], table.find(activeLocks[key], lockId))
			ctx.log(
				"info",
				`store({ctx.name}) key({key}) lockId({lockId}) post-lock expiryThread: {lockExpiryThread} {lockCounter}`
			)
			locked = false
			ctx.log("info", `store({ctx.name}) key({key}) lockId({lockId}) Lock released from util`)
		end)
	end

	local function lock()
		ctx.log("info", `store({ctx.name}) key({key}) lockId({lockId}) Lock called`)
		local function transformFunction(otherLockId: string?): string?
			if otherLockId == nil or otherLockId == lockId then
				return lockId
			end

			return nil
		end

		curLockPromise = Promise.new(function(resolve, reject, onCancel)
			local updatePromise: any
			onCancel(function()
				release():catch(function(err)
					ctx.log("error", `store({ctx.name}) key({key}) lockId({lockId}) Error releasing lock: {err}`)
				end)
				if updatePromise then
					updatePromise:cancel()
				end
			end)

			for i = 1, params.acquireAttempts do
				updatePromise = ctx.hashMapInterface:update(scope, key, transformFunction, params.duration)
				local resolved, lastValue = updatePromise:await()
				updatePromise = nil

				if resolved and lastValue ~= nil then
					lastUpdate = os.clock()
					return resolve()
				end

				if i ~= params.acquireAttempts then
					ctx.log(
						"info",
						`store({ctx.name}) key({key}) lockId({lockId}) Retrying lock acquisition (attempt {i})`
					)
					local retryAfter = math.min(2 ^ (i - 1), 30)
					task.wait(retryAfter)
				end
			end

			ctx.log(
				"error",
				`store({ctx.name}) key({key}) lockId({lockId}) Failed to acquire lock after {params.acquireAttempts} attempts`
			)
			return reject("Failed to acquire lock")
		end):tap(function()
			if lockExpiryThread then
				lockCounter -= 1
				task.cancel(lockExpiryThread)
				lockExpiryThread = nil
			end

			version += 1
			local myVersion = version

			ctx.log("info", `store({ctx.name}) key({key}) lockId({lockId}) Lock acquired. spawning expiry`)
			lockExpiryThread = task.delay(params.duration, task.spawn, function()
				if myVersion ~= version then
					warn(`store({ctx.name}) key({key}) lockId({lockId}) Lock has more than one expiry thread`)
				end

				ctx.log("warn", `store({ctx.name}) key({key}) lockId({lockId}) Lock expired`)
				local tSinceLast = os.clock() - lastUpdate
				warn(
					`store({ctx.name}) key({key}) lockId({lockId}) lock lost, locked: {locked}, lockExpiryThread: {lockExpiryThread}, activeLock: {activeLocks[key]}, tSinceLast: {tSinceLast}`
				)
				warn(activeLocks[key])
				table.remove(activeLocks[key], table.find(activeLocks[key], lockId))

				locked = false

				refreshLock = false
				if curLockPromise then
					curLockPromise:cancel()
				end

				for _, callback in onLockLostCallbacks do
					task.spawn(callback)
				end
			end)
			lockCounter += 1

			if lockCounter > 1 then
				warn("store({ctx.name}) key({key}) lockId({lockId}) too many threads", key, lockCounter)
			end

			if not table.find(activeLocks[key], lockId) then
				table.insert(activeLocks[key], lockId)
			end
			locked = true
		end)

		curLockPromise:finally(function()
			curLockPromise = nil
		end)

		return curLockPromise or Promise.resolve()
	end

	local function lockRefreshLoop()
		refreshLock = true
		while true do
			task.wait(params.refreshInterval)
			if not refreshLock then
				break
			end

			local lockPromise = lock()
			local resolved, err = lockPromise:await()

			if not resolved then
				local status = lockPromise:awaitStatus()
				if status ~= (Promise :: any).Status.Cancelled then
					ctx.log("warn", `store({ctx.name}) key({key}) lockId({lockId}) Failed to refresh lock: {err}`)
				else
					ctx.log("info", `store({ctx.name}) key({key}) lockId({lockId}) Lock refresh cancelled`)
				end
			else
				ctx.log("info", `store({ctx.name}) key({key}) lockId({lockId}) Lock refreshed`)
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
		ctx.log("info", `store({ctx.name}) key({key}) lockId({lockId}) Lock successfully acquired`)

		task.spawn(lockRefreshLoop)

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
	activeLocks = activeLocks,
}
