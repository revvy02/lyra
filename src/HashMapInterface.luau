--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)

local MAX_RETRIES = 5
local RETRY_ERROR_CODES = {
	"TotalRequestsOverLimit",
}

type HashMapInterfaceImpl = {
	__index: HashMapInterfaceImpl,
	_getHashMap: (self: HashMapInterface, scope: string) -> MemoryStoreHashMap,
	_retry: (self: HashMapInterface, func: () -> any) -> Promise.TypedPromise<any>,
	new: (memoryStoreService: MemoryStoreService) -> HashMapInterface,
	get: (self: HashMapInterface, scope: string, key: string) -> Promise.TypedPromise<any?>,
	set: (
		self: HashMapInterface,
		scope: string,
		key: string,
		value: any,
		expiration: number
	) -> Promise.TypedPromise<boolean>,
	update: (
		self: HashMapInterface,
		scope: string,
		key: string,
		transformFunction: (currentValue: any?) -> any?,
		expiration: number
	) -> Promise.TypedPromise<any?>,
	remove: (self: HashMapInterface, scope: string, key: string) -> Promise.Promise,
}

type HashMapInterfaceProps = {
	_memoryStoreService: MemoryStoreService,
	_hashMaps: { [string]: MemoryStoreHashMap },
}

export type HashMapInterface = typeof(setmetatable({} :: HashMapInterfaceProps, {} :: HashMapInterfaceImpl))

local HashMapInterface: HashMapInterfaceImpl = {} :: HashMapInterfaceImpl
HashMapInterface.__index = HashMapInterface

function HashMapInterface.new(memoryStoreService: MemoryStoreService): HashMapInterface
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

function HashMapInterface:_retry(func: () -> any): Promise.TypedPromise<any>
	return Promise.new(function(resolve, reject)
		for i = 1, MAX_RETRIES do
			if i > 1 then
				local retryAfter = 2 ^ (i - 1)
				task.wait(retryAfter)
			end

			local result = table.pack(pcall(func))
			if result[1] == true then
				return resolve(table.unpack(result, 2))
			end

			for _, errorCode in RETRY_ERROR_CODES do
				if result[2]:find(errorCode) then
					continue
				end
			end

			return reject(`HashMap error: {result[2]}`)
		end
		return reject("HashMap error: too many retries")
	end)
end

function HashMapInterface:get(scope: string, key: string): Promise.TypedPromise<any?>
	local hashMap = self:_getHashMap(scope)
	return self:_retry(function()
		return hashMap:GetAsync(key)
	end)
end

function HashMapInterface:set(scope: string, key: string, value: any, expiration: number): Promise.TypedPromise<boolean>
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
): Promise.TypedPromise<any?>
	local hashMap = self:_getHashMap(scope)
	return self:_retry(function()
		return hashMap:UpdateAsync(key, transformFunction, expiration)
	end) :: any
end

function HashMapInterface:remove(scope: string, key: string): Promise.Promise
	local hashMap = self:_getHashMap(scope)
	return self:_retry(function()
		return hashMap:RemoveAsync(key)
	end)
end

return HashMapInterface
