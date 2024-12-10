--!strict

local HttpService = game:GetService("HttpService")

local Tables = require(script.Parent.Tables)

local requestQueues = {
	GetAsync = {},
	SetAsync = {},
	UpdateAsync = {},
	RemoveAsync = {},
}
local MAX_QUEUE_SIZE = 30
local RATE_LIMITS = {
	GetAsync = { Base = 100, PlayerMultiplier = 10 },
	SetAsync = { Base = 100, PlayerMultiplier = 10 },
	UpdateAsync = { Base = 100, PlayerMultiplier = 10 },
	RemoveAsync = { Base = 100, PlayerMultiplier = 10 },
}

local MAX_KEY_LENGTH = 128
local MAX_VALUE_SIZE = 32 * 1024 -- 32KB
local MAX_UPDATE_RETRIES = 3
local MAX_EXPIRATION = 3888000 -- 45 days in seconds

local function delayWait(n: number)
	local thread = coroutine.running()
	task.delay(n, function()
		coroutine.resume(thread)
	end)
	coroutine.yield()
end

local function getNow()
	return DateTime.now().UnixTimestampMillis
end

local function doRateLimitAndQueue(requestType)
	local queue = requestQueues[requestType]
	local limitData = RATE_LIMITS[requestType]
	local currentPlayers = 15
	local requestsPerMinute = limitData.Base + (currentPlayers * limitData.PlayerMultiplier)

	if #queue >= requestsPerMinute then
		error("TotalRequestsOverLimit", 2)
	end

	if #queue >= MAX_QUEUE_SIZE then
		error("RequestThrottled", 2)
	end

	table.insert(queue, true)
	delayWait(0.01)
	local fn = table.remove(queue, 1)
	if typeof(fn) == "function" then
		fn()
	end
end

local function enforceKeyLimits(key: string)
	if typeof(key) ~= "string" then
		error("InvalidRequest: key must be a string", 2)
	end
	if #key == 0 then
		error("InvalidRequest: key cannot be empty", 2)
	end
	if #key > MAX_KEY_LENGTH then
		error("InvalidRequest: key length exceeds limit", 2)
	end
end

local function enforceValueLimits(value: any)
	if value == nil then
		return
	end

	local success, encoded = pcall(function()
		return game:GetService("HttpService"):JSONEncode(value)
	end)

	if not success then
		error("InvalidRequest: value cannot be encoded to JSON", 2)
	end

	if #encoded > MAX_VALUE_SIZE then
		error("ItemValueSizeTooLarge", 2)
	end
end

local function enforceExpirationLimits(expiration: number)
	if typeof(expiration) ~= "number" then
		error("InvalidRequest: expiration must be a number", 2)
	end
	if expiration <= 0 then
		error("InvalidRequest: expiration must be greater than 0", 2)
	end
	if expiration > MAX_EXPIRATION then
		error("InvalidRequest: expiration exceeds maximum", 2)
	end
end

local function createMockHashMap(name: string, mockData): any
	local tbl = {
		name = name,
	}

	local function getScopedData(self: any)
		local hashMap = mockData[self.name]
		if not hashMap then
			hashMap = {}
			mockData[self.name] = hashMap
		end
		return hashMap
	end

	local function isExpired(entry: any): boolean
		if not entry or not entry.expiration then
			return true
		end
		return getNow() > entry.expiration
	end

	tbl.GetAsync = function(self, key: string): any?
		enforceKeyLimits(key)

		doRateLimitAndQueue("GetAsync")

		delayWait(0.1)

		local scopedData = getScopedData(self)
		local entry = scopedData[key]

		if isExpired(entry) then
			scopedData[key] = nil
			return nil
		end

		return entry.value
	end

	tbl.SetAsync = function(self, key: string, value: any, expiration: number): boolean
		enforceKeyLimits(key)
		enforceValueLimits(value)
		enforceExpirationLimits(expiration)

		doRateLimitAndQueue("SetAsync")
		delayWait(0.1)

		local scopedData = getScopedData(self)
		local serialized = HttpService:JSONEncode(value)
		if serialized == nil then
			return false
		end

		scopedData[key] = {
			value = value,
			expiration = getNow() + expiration * 1000,
		}

		return true
	end

	tbl.UpdateAsync = function(self, key: string, transformFunction: (any?) -> any?, expiration: number): any?
		enforceKeyLimits(key)
		enforceExpirationLimits(expiration)

		doRateLimitAndQueue("UpdateAsync")
		delayWait(0.1)

		local scopedData = getScopedData(self)
		local retries = 0

		while retries < MAX_UPDATE_RETRIES do
			local entry = scopedData[key]
			local currentValue = nil

			if not isExpired(entry) then
				currentValue = Tables.copyDeep(entry.value)
			end

			local success, newValue = pcall(transformFunction, currentValue)
			if not success then
				error("TransformCallbackFailed", 2)
			end

			if newValue == nil then
				scopedData[key] = nil
				return nil
			end

			enforceValueLimits(newValue)

			if entry and not isExpired(entry) and not Tables.equalsDeep(entry.value, currentValue) then
				retries += 1
				if retries >= MAX_UPDATE_RETRIES then
					error("DataUpdateConflict", 2)
				end
				continue
			end

			scopedData[key] = {
				value = newValue,
				expiration = getNow() + expiration * 1000,
			}

			return newValue
		end

		error("UpdateConflict: Exceeded max number of retries", 2)
	end

	tbl.RemoveAsync = function(self, key: string)
		enforceKeyLimits(key)

		doRateLimitAndQueue("RemoveAsync")
		delayWait(0.1)

		local scopedData = getScopedData(self)
		scopedData[key] = nil
	end

	return tbl
end

local function createMockService()
	local tbl = {
		_mockData = {},
		_hashMaps = {},
	}

	tbl.GetHashMap = function(self, name: string): any
		if not self._hashMaps[name] then
			self._hashMaps[name] = createMockHashMap(name, tbl._mockData)
		end
		return self._hashMaps[name]
	end

	return tbl
end

return {
	createMockService = createMockService,
}
