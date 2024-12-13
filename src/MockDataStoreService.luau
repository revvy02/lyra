--!strict

local Tables = require(script.Parent.Tables)

local MAX_QUEUE_SIZE = 30
local RATE_LIMITS = {
	GetAsync = { Base = 60, PlayerMultiplier = 10 },
	SetAsync = { Base = 60, PlayerMultiplier = 10 },
	UpdateAsync = { Base = 60, PlayerMultiplier = 10 },
	RemoveAsync = { Base = 60, PlayerMultiplier = 10 },
	GetVersion = { Base = 5, PlayerMultiplier = 2 },
}

local MAX_KEY_LENGTH = 50
local MAX_DATA_SIZE = 4_194_304
local MAX_METADATA_SIZE = 300
local CACHE_DURATION = 4

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

local function msToHours(ms: number)
	return math.floor(ms / (60 * 60 * 1000))
end

local function getUtcHour()
	return msToHours(getNow())
end

local function createVersion(value: any, userIds: any, metadata: any)
	return {
		Value = value,
		UserIds = userIds or {},
		Metadata = metadata or {},
		CreatedTime = getNow(),
		Version = tostring(getNow()),
	}
end

local function createMockKeyInfo(userIds: any, metadata: any)
	local info = {
		CreatedTime = getNow(),
		UpdatedTime = getNow(),
		Version = tostring(getNow()),
		userIds = userIds or {},
		metadata = metadata or {},
		GetUserIds = function(self)
			return self.userIds
		end,
		GetMetadata = function(self)
			return self.metadata
		end,
	}
	return info
end

local function validateMetadata(metadata: any)
	if metadata == nil then
		return
	end

	if typeof(metadata) ~= "table" then
		error("DataStoreService: Metadata must be a table", 2)
	end

	local serialized = game:GetService("HttpService"):JSONEncode(metadata)
	if #serialized > MAX_METADATA_SIZE then
		error(`DataStoreService: Metadata size exceeds {MAX_METADATA_SIZE} limit`, 2)
	end
end

local function createMockStore(service: any, datastoreName: string, scope: string?)
	local tbl = {
		datastoreName = datastoreName,
		scope = scope or "global",
		_service = service,
	}

	local function getScopedData(self: any)
		local datastore = self._service.mockData[self.datastoreName]
		if not datastore then
			datastore = {}
			self._service.mockData[self.datastoreName] = datastore
		end

		local scopedData = datastore[self.scope]
		if not scopedData then
			scopedData = {}
			datastore[self.scope] = scopedData
		end

		return scopedData
	end

	local function getVersionsForKey(self: any, key: string)
		local versionKey = `{self.datastoreName}|{self.scope}|{key}`
		if not self._service.mockVersions[versionKey] then
			self._service.mockVersions[versionKey] = {}
		end
		return self._service.mockVersions[versionKey]
	end

	local function getCacheKey(self: any, key: string)
		return `{self.datastoreName}|{self.scope}|{key}`
	end

	local function getCachedValue(self: any, key: string)
		local cacheKey = getCacheKey(self, key)
		local cached = self._service.mockCache[cacheKey]
		if cached and (os.time() - cached.timestamp) < CACHE_DURATION then
			return cached.value, cached.keyInfo
		end
		return nil, nil :: any
	end

	local function setCachedValue(self: any, key: string, value: any, keyInfo: any)
		local cacheKey = getCacheKey(self, key)
		self._service.mockCache[cacheKey] = {
			value = value,
			keyInfo = keyInfo,
			timestamp = os.time(),
		}
	end

	local function enforceKeyLimits(key: any)
		if typeof(key) ~= "string" then
			error("DataStoreService: Key must be a string", 2)
		end

		if #key == 0 then
			error("DataStoreService: Key name can't be empty", 2)
		end

		if #key > MAX_KEY_LENGTH then
			error(`DataStoreService: Key name exceeds the {MAX_KEY_LENGTH} character limit`, 2)
		end
	end

	local function enforceDataLimits(value: any)
		if value == nil then
			return
		end

		local success, result = pcall(function()
			return game:GetService("HttpService"):JSONEncode(value)
		end)
		if not success then
			error(`DataStoreService: Cannot store {typeof(value)} in DataStore`, 2)
		end

		if #result > MAX_DATA_SIZE then
			error(`DataStoreService: Serialized value exceeds {MAX_DATA_SIZE} limit`, 2)
		end
	end

	local function doRateLimitAndQueue(self: any, requestType: string)
		local queue = self._service.requestQueues[requestType]
		local limitData = RATE_LIMITS[requestType]
		if not limitData then
			limitData = RATE_LIMITS.GetAsync
		end
		local currentPlayers = 15
		local requestsPerMinute = limitData.Base + (currentPlayers * limitData.PlayerMultiplier)

		if #queue >= requestsPerMinute then
			return false
		end

		if #queue >= MAX_QUEUE_SIZE then
			error(
				`DataStoreService:{requestType}() request dropped. Request was throttled, but throttled request queue was full`,
				2
			)
		end

		table.insert(queue, true)
		delayWait(0.01)
		local fn = table.remove(queue, 1)
		if typeof(fn) == "function" then
			fn()
		end

		return true
	end

	tbl.SetAsync = function(self, key, value, userIds, options)
		enforceKeyLimits(key)
		enforceDataLimits(value)
		if options then
			validateMetadata(options:GetMetadata())
		end

		doRateLimitAndQueue(self, "SetAsync")

		delayWait(0.1)

		local scopedData = getScopedData(self)
		local versions = getVersionsForKey(self, key)
		local currentHour = getUtcHour()

		if #versions == 0 or msToHours(versions[#versions].CreatedTime) ~= currentHour then
			table.insert(versions, createVersion(value, userIds, options and options:GetMetadata()))
		else
			local currentVersion = versions[#versions]
			currentVersion.Value = value
			if userIds then
				currentVersion.UserIds = userIds
			end
			if options then
				currentVersion.Metadata = options:GetMetadata() or {}
			end
		end

		local latestVersion = versions[#versions].Version
		scopedData[key] = value
		local keyInfo = createMockKeyInfo(userIds, options and options:GetMetadata())
		self._service.mockKeyInfo[`{self.datastoreName}|{self.scope}|{key}`] = keyInfo

		setCachedValue(self, key, value, keyInfo)

		return latestVersion
	end

	tbl.GetAsync = function(self, key)
		enforceKeyLimits(key)

		local cachedValue, cachedKeyInfo = getCachedValue(self, key)
		if cachedValue ~= nil then
			return cachedValue, cachedKeyInfo
		end

		doRateLimitAndQueue(self, "GetAsync")

		delayWait(0.1)

		local scopedData = getScopedData(self)
		local data = scopedData[key]
		local keyInfo = self._service.mockKeyInfo[`{self.datastoreName}|{self.scope}|{key}`]

		if data ~= nil then
			setCachedValue(self, key, data, keyInfo)
		end

		return data, keyInfo
	end

	tbl.UpdateAsync = function(self, key, transformFunction)
		enforceKeyLimits(key)

		doRateLimitAndQueue(self, "UpdateAsync")

		while true do
			local scopedData = getScopedData(self)
			local keyInfo = self._service.mockKeyInfo[`{self.datastoreName}|{self.scope}|{key}`] or createMockKeyInfo()
			local currentValue = scopedData[key]
			local valueForCallback = currentValue ~= nil and Tables.copyDeep(currentValue)

			local newValue, newUserIds, newMetadata = transformFunction(valueForCallback, keyInfo)
			if newValue == nil then
				return currentValue, keyInfo
			end

			enforceDataLimits(newValue)
			validateMetadata(newMetadata)

			if not Tables.equalsDeep(currentValue, scopedData[key]) then
				continue
			end

			local versions = getVersionsForKey(self, key)
			local currentHour = getUtcHour()

			if #versions == 0 or versions[#versions].CreatedTime ~= currentHour then
				table.insert(
					versions,
					createVersion(newValue, newUserIds or keyInfo:GetUserIds(), newMetadata or keyInfo:GetMetadata())
				)
			else
				local currentVersion = versions[#versions]
				currentVersion.Value = newValue
				if newUserIds then
					currentVersion.UserIds = newUserIds
				end
				if newMetadata then
					currentVersion.Metadata = newMetadata
				end
			end

			scopedData[key] = newValue
			if newUserIds ~= nil then
				keyInfo.userIds = newUserIds
			end
			if newMetadata ~= nil then
				keyInfo.metadata = newMetadata
			end
			keyInfo.UpdatedTime = getNow()
			keyInfo.Version = tostring(getNow())

			setCachedValue(self, key, newValue, keyInfo)
			return newValue, keyInfo
		end
	end

	tbl.RemoveAsync = function(self, key)
		enforceKeyLimits(key)

		doRateLimitAndQueue(self, "RemoveAsync")

		delayWait(0.01)

		local scopedData = getScopedData(self)
		local data = scopedData[key]
		local keyInfo = self._service.mockKeyInfo[`{self.datastoreName}|{self.scope}|{key}`]

		if data ~= nil then
			local versions = getVersionsForKey(self, key)
			table.insert(versions, createVersion(nil, nil, nil))
		end

		scopedData[key] = nil

		local cacheKey = getCacheKey(self, key)
		self._service.mockCache[cacheKey] = nil

		return data, keyInfo
	end

	tbl.GetVersionAsync = function(self, key, version)
		enforceKeyLimits(key)

		doRateLimitAndQueue(self, "GetVersion")

		local versions = getVersionsForKey(self, key)
		for _, v in versions do
			if v.Version == version then
				return v.Value, createMockKeyInfo(v.UserIds, v.Metadata)
			end
		end
		return nil, nil :: any
	end

	tbl.ListVersionsAsync = function(self, key, sortDirection, minDate, maxDate)
		enforceKeyLimits(key)

		doRateLimitAndQueue(self, "GetVersion")

		local versions = getVersionsForKey(self, key)
		local results = {}

		for _, v in versions do
			if (not minDate or v.CreatedTime >= minDate) and (not maxDate or v.CreatedTime <= maxDate) then
				table.insert(results, {
					Version = v.Version,
					CreatedTime = v.CreatedTime,
				})
			end
		end

		if sortDirection == Enum.SortDirection.Descending then
			table.sort(results, function(a, b)
				return a.CreatedTime > b.CreatedTime
			end)
		else
			table.sort(results, function(a, b)
				return a.CreatedTime < b.CreatedTime
			end)
		end

		return {
			IsFinished = true,
			GetCurrentPage = function()
				return results
			end,
		}
	end

	tbl._setInternalData = function(self, newData, newKeyInfo)
		self._service.mockData[self.datastoreName] = newData
		self._service.mockKeyInfo = newKeyInfo
	end

	tbl._queueError = function(self, requestType, errorMessage)
		table.insert(self._service.queuedErrors[requestType], errorMessage)
	end

	return tbl
end

local function createMockService()
	local tbl = {
		dataStores = {},
		mockData = {},
		mockKeyInfo = {},
		mockVersions = {},
		mockCache = {},
		requestQueues = {
			GetAsync = {},
			SetAsync = {},
			UpdateAsync = {},
			RemoveAsync = {},
			GetVersion = {},
		},
		queuedErrors = {
			GetAsync = {},
			SetAsync = {},
			UpdateAsync = {},
			RemoveAsync = {},
		},
	}

	tbl.GetDataStore = function(self, datastoreName: string, scope: string?)
		local store = self.dataStores[`{datastoreName}{scope or ""}`]
		if not store then
			store = createMockStore(self, datastoreName, scope)
			self.dataStores[`{datastoreName}{scope or ""}`] = store
		end
		return store
	end

	tbl.GetRequestBudgetForRequestType = function(self, requestType: Enum.DataStoreRequestType)
		local requestTypeStr = tostring(requestType):gsub("Enum.DataStoreRequestType.", "")

		if self._customBudgets[requestTypeStr] then
			return self._customBudgets[requestTypeStr]
		end

		local limitData = RATE_LIMITS[requestTypeStr]
		if not limitData then
			limitData = RATE_LIMITS.GetAsync
		end

		local currentPlayers = 15
		local totalBudget = limitData.Base + (currentPlayers * limitData.PlayerMultiplier)

		local queueKey = requestTypeStr
		if requestTypeStr == "GetVersionAsync" then
			queueKey = "GetVersion"
		end

		local currentQueueSize = #self.requestQueues[queueKey]
		return math.max(0, totalBudget - currentQueueSize)
	end

	return (tbl :: any) :: DataStoreService
end

return {
	createMockService = createMockService,
}
