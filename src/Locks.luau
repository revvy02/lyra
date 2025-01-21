--!strict

local HttpService = game:GetService("HttpService")

local LOCK_TTL_ERROR_MARGIN_SECS = 0.2

local Types = require(script.Parent.Types)
local Promise = require(script.Parent.Promise)
local hashMapRetry = require(script.Parent.hashMapRetry)

type LockStatus = "acquiring" | "held" | "released"

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

local function acquireLock(params: AcquireLockParams): Promise.TPromise<LockHandle>
	local lockId = HttpService:GenerateGUID(false)
	local expiredCallbacks: { () -> () } = {}
	local expiryThread: thread? = nil
	local refreshPromise: Promise.Promise? = nil

	local status: LockStatus
	local lastConfirmedExpiry = nil

	local ctx = params.storeContext
	local key = params.key
	local logger = ctx.logger:extend({ method = "acquireLock", key = key, lockId = lockId })

	local function transitionTo(newStatus: LockStatus)
		logger:log("trace", `lock transition: {status} -> {newStatus}`)
		status = newStatus
	end

	local function spawnExpiryCallbacks()
		if status == "held" then
			for _, callback in expiredCallbacks do
				task.spawn(callback)
			end
		end
	end

	local function tryUpdate(ttl: number)
		logger:log("trace", `attempting update with ttl {ttl}`)
		local function transformFunction(otherLockId: string?): string?
			if otherLockId == nil or otherLockId == lockId then
				return lockId
			end
			return nil
		end

		local retryHandle = hashMapRetry(function()
			return ctx.lockHashMap:UpdateAsync(key, transformFunction, ttl)
		end)

		retryHandle.promise:tap(function(value)
			if value ~= nil then
				lastConfirmedExpiry = os.clock() + ttl - LOCK_TTL_ERROR_MARGIN_SECS

				if expiryThread then
					task.cancel(expiryThread)
				end

				if ttl > 0 then
					expiryThread = task.delay(ttl, spawnExpiryCallbacks)
				end
			end
		end)

		return retryHandle
	end

	local function release(): Promise.Promise
		logger:log("trace", "releasing lock")

		if status ~= "held" then
			logger:log("trace", "release already called")
			return Promise.resolve()
		end
		transitionTo("released")

		if expiryThread then
			task.cancel(expiryThread)
			expiryThread = nil
		end

		if refreshPromise then
			refreshPromise:cancel()
			refreshPromise = nil
		end

		local isAcquired = lastConfirmedExpiry and lastConfirmedExpiry > os.clock()
		if isAcquired then
			return tryUpdate(0).promise
		end

		return Promise.resolve()
	end

	local function waitForLock()
		logger:log("trace", "acquiring lock")

		transitionTo("acquiring")

		local start = os.clock()
		local currentRetry: Types.RetryHandle<Promise.TPromise<any>>? = nil
		local attemptCount = 0

		return Promise.new(function(resolve, reject, onCancel)
			onCancel(function()
				local p = Promise.resolve()
				if currentRetry then
					currentRetry.cancel()
					p = currentRetry.promise
				end

				p:finally(function()
					release():catch(function(err)
						logger:log("error", "failed to unlock", { error = err })
					end)
				end)
			end)

			-- Using a separate thread to handle results of in-flight requests,
			-- since Promise:cancel() would abruptly stop execution via
			-- coroutine.close
			task.spawn(function()
				while (os.clock() - start) < params.duration do
					if onCancel() then
						return
					end

					attemptCount += 1
					currentRetry = tryUpdate(params.duration)
					local resolved, value = (currentRetry :: any).promise:await()
					currentRetry = nil

					if resolved and value ~= nil then
						transitionTo("held")
						return resolve()
					elseif not resolved then
						logger:log("warn", "attempt to acquire lock failed", {
							attemptCount = attemptCount,
							error = value,
						})
					end

					if onCancel() then
						return
					end

					local retryAfter = math.min(2 ^ (attemptCount - 1), 30)
					task.wait(retryAfter)
				end

				return reject("lock remained")
			end)
		end)
	end

	local function setupLockRefresh()
		logger:log("trace", "setting up lock refresh")

		local currentRefreshHandle: Types.RetryHandle<Promise.TPromise<any>>? = nil

		refreshPromise = Promise.new(function(resolve, _, onCancel)
			onCancel(function()
				if currentRefreshHandle then
					currentRefreshHandle.cancel()
				end
			end)

			task.spawn(function()
				while status == "held" do
					task.wait(params.refreshInterval)

					if onCancel() or status ~= "held" then
						break
					end

					currentRefreshHandle = tryUpdate(params.duration)
					local resolved, value = (currentRefreshHandle :: any).promise:await()
					currentRefreshHandle = nil

					if status ~= "held" then
						break
					end

					if not resolved or value == nil then
						logger:log("warn", "failed to refresh lock", { error = value })
						transitionTo("released")
						break
					end
				end

				resolve()
			end)
		end)
	end

	local lockHandle = {
		release = release,
		isLocked = function()
			return status == "held" and (lastConfirmedExpiry or 0) > os.clock()
		end,
		onLockLost = function(callback)
			table.insert(expiredCallbacks, callback)
			return function()
				local idx = table.find(expiredCallbacks, callback)
				if idx then
					table.remove(expiredCallbacks, idx)
				end
			end
		end,
	}

	return waitForLock()
		:andThen(function()
			setupLockRefresh()
			return lockHandle
		end)
		:catch(function(err)
			logger:log("error", "failed to acquire lock", { error = err })
			return release():andThen(function()
				return Promise.reject(err)
			end)
		end)
end

export type ProbeLockActiveParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
}

local function probeLockActive(params: ProbeLockActiveParams): Promise.TPromise<boolean>
	local ctx = params.storeContext
	local key = params.key
	local logger = ctx.logger:extend({ method = "probeLockActive", key = key })

	logger:log("trace", "probing if lock is active")

	local retryHandle = hashMapRetry(function()
		return ctx.lockHashMap:GetAsync(key)
	end)

	return retryHandle.promise:andThen(function(value)
		return value ~= nil
	end)
end

return {
	acquireLock = acquireLock,
	probeLockActive = probeLockActive,
}
