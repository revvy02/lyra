--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Types = require(script.Parent.Types)

local MAX_RETRIES = 5
local RETRY_ERROR_CODES = {
	"TotalRequestsOverLimit",
	"InternalError",
	"Throttled",
	"PartitionRequestsOverLimit",
}
local ERROR_RATE = 0

local HashMapInterface: Types.HashMapInterfaceImpl = {} :: Types.HashMapInterfaceImpl
HashMapInterface.__index = HashMapInterface

function HashMapInterface.new(memoryStoreService: MemoryStoreService): Types.HashMapInterface
	local self = setmetatable({
		_memoryStoreService = memoryStoreService,
		_hashMaps = {},
	}, HashMapInterface)
	return self
end

function HashMapInterface:_getHashMap(scope: string): MemoryStoreHashMap
	if not self._hashMaps[scope] then
		self._hashMaps[scope] = self._memoryStoreService:GetHashMap(scope)
	end
	return self._hashMaps[scope]
end

function HashMapInterface:_retry(func: () -> any): Types.RetryHandle<Promise.TypedPromise<any>>
	local cancel = false

	local handle: Types.RetryHandle<Promise.TypedPromise<any>> = {
		promise = Promise.new(function(resolve, reject)
			local lastError
			for i = 1, MAX_RETRIES do
				if i > 1 and not cancel then
					local retryAfter = 2 ^ (i - 1)
					task.wait(retryAfter)
				end

				if cancel then
					return reject(`HashMap error: operation cancelled`)
				end

				if math.random() < ERROR_RATE then
					return reject(`HashMap error: Simulated MemoryStore error`)
				end

				local result = table.pack(pcall(func))
				if result[1] == true then
					return resolve(table.unpack(result, 2))
				end

				lastError = result[2]

				local retry = false

				for _, errorCode in RETRY_ERROR_CODES do
					if result[2]:find(errorCode, 0, true) then
						retry = true
						break
					end
				end

				if retry then
					continue
				end

				return reject(`HashMap error: {result[2]}`)
			end
			return reject(`HashMap error: too many retries. Last error: {lastError}`)
		end),
		cancel = function()
			cancel = true
		end,
	}

	return handle
end

function HashMapInterface:get(scope: string, key: string): Types.RetryHandle<Promise.TypedPromise<any?>>
	local hashMap = self:_getHashMap(scope)
	return self:_retry(function()
		return hashMap:GetAsync(key)
	end)
end

function HashMapInterface:set(
	scope: string,
	key: string,
	value: any,
	expiration: number
): Types.RetryHandle<Promise.TypedPromise<boolean>>
	local hashMap = self:_getHashMap(scope)
	return self:_retry(function()
		return hashMap:SetAsync(key, value, expiration)
	end)
end

function HashMapInterface:update(
	scope: string,
	key: string,
	transformFunction: (currentValue: any?) -> any?,
	expiration: number
): Types.RetryHandle<Promise.TypedPromise<any?>>
	local hashMap = self:_getHashMap(scope)
	return self:_retry(function()
		return hashMap:UpdateAsync(key, transformFunction, expiration)
	end) :: any
end

function HashMapInterface:remove(scope: string, key: string): Types.RetryHandle<Promise.Promise>
	local hashMap = self:_getHashMap(scope)
	return self:_retry(function()
		return hashMap:RemoveAsync(key)
	end)
end

return HashMapInterface
