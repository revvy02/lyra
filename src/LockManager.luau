local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LOCK_DURATION_SECONDS = 2 * 60

local Constants = require(script.Parent.Constants)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local Types = require(script.Parent.Types)

local LockManager = {}
LockManager.__index = LockManager

function LockManager.new(dataStoreInterface: Types.DataStoreInterface)
	local self = setmetatable({
		_dataStoreInterface = dataStoreInterface,
		_lockId = HttpService:GenerateGUID(false),
	}, LockManager)
	return self
end

function LockManager:lock(key: string): Promise.Promise
	return self._dataStoreInterface
		:update(Constants.RECORD_SCOPE, key, function(value)
			value = Sift.Dictionary.mergeDeep({ _metadata = {} }, value)

			local meta = value._metadata
			if meta.lock_expiry ~= nil and meta.lock_expiry > DateTime.now().UnixTimestamp then
				return nil
			end

			meta.lock_id = self._lockId
			value = self:refreshLockExpiry(value)

			return value
		end)
		:andThen(function(latestValue)
			if latestValue._metadata.lock_id ~= self._lockId then
				return Promise.reject("Failed to acquire lock")
			end
			return latestValue
		end)
end

function LockManager:unlock(key: string): Promise.Promise
	return self._dataStoreInterface:update(Constants.RECORD_SCOPE, key, function(value)
		local meta = value._metadata
		if meta.lock_id == self._lockId then
			meta.lock_id = nil
			meta.lock_expiry = nil
		end
		return value
	end)
end

function LockManager:refreshLockExpiry(value: any): any
	return Sift.Dictionary.mergeDeep(value, {
		_metadata = {
			lock_expiry = DateTime.now().UnixTimestamp + LOCK_DURATION_SECONDS,
		},
	})
end

return LockManager
