--!strict

local Tables = require(script.Parent.Tables)

local mockData = {}
local mockKeyInfo = {}

local requestQueues = {
	GetAsync = {},
	SetAsync = {},
	UpdateAsync = {},
	RemoveAsync = {},
}
local queuedErrors = {
	GetAsync = {},
	SetAsync = {},
	UpdateAsync = {},
	RemoveAsync = {},
}
local MAX_QUEUE_SIZE = 30
local RATE_LIMITS = {
	GetAsync = { Base = 60, PlayerMultiplier = 10 },
	SetAsync = { Base = 60, PlayerMultiplier = 10 },
	UpdateAsync = { Base = 60, PlayerMultiplier = 10 },
	RemoveAsync = { Base = 60, PlayerMultiplier = 10 },
}

local MAX_KEY_LENGTH = 50
local MAX_DATA_SIZE = 4_194_304

-- Custom delay function for Jest fake timers
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

local function createMockKeyInfo(userIds: any, metadata: any)
	local tbl = {
		CreatedTime = getNow(),
		UpdatedTime = getNow(),
		userIds = userIds or {},
		metadata = metadata or {},
	}
	tbl.GetUserIds = function(self)
		return self.userIds
	end
	tbl.GetMetadata = function(self)
		return self.metadata
	end
	return tbl
end

local function createMockStore(datastoreName: string, scope: string?): DataStoreService
	local tbl = {
		datastoreName = datastoreName,
		scope = scope or "global",
	}

	local function getScopedData(self: any)
		local datastore = mockData[self.datastoreName]
		if not datastore then
			datastore = {}
			mockData[self.datastoreName] = datastore
		end

		local scopedData = datastore[self.scope]
		if not scopedData then
			scopedData = {}
			datastore[self.scope] = scopedData
		end

		return scopedData
	end

	local function enforceKeyLimits(key: any)
		if #key == 0 then
			error("DataStoreService:SetAsync() Key name can't be empty.", 2) -- Error code 101
		end

		if #key > MAX_KEY_LENGTH then
			error(`DataStoreService:SetAsync() Key name exceeds the {MAX_KEY_LENGTH} character limit.`, 2) -- Error code 102
		end
	end

	local function enforceDataLimits(value: any)
		local success = pcall(function()
			game:GetService("HttpService"):JSONEncode(value)
		end)
		if not success then
			error(`DataStoreService:SetAsync() Cannot store {typeof(value)} in DataStore.`, 2) -- Error code 104, include serialization error
		end

		local serializedValue = game:GetService("HttpService"):JSONEncode(value)
		if #serializedValue > MAX_DATA_SIZE then
			error(`DataStoreService:SetAsync() Serialized value exceeds {MAX_DATA_SIZE} limit.`, 2) -- Error code 105
		end
	end

	local function checkRateLimit(requestType)
		local queue = requestQueues[requestType]
		local limitData = RATE_LIMITS[requestType]
		local currentPlayers = 15
		local requestsPerMinute = limitData.Base + (currentPlayers * limitData.PlayerMultiplier)

		if #queue >= requestsPerMinute then
			return false
		end

		return true
	end

	local function enqueueRequest(requestType)
		local queue = requestQueues[requestType]
		if #queue >= MAX_QUEUE_SIZE then
			error(
				`DataStoreService:{requestType}() request dropped. Request was throttled, but throttled request queue was full.`,
				2
			) -- Error code 302, 304, or 306
		end

		table.insert(queue, true)
		delayWait(0.01)
		local fn = table.remove(queue, 1)
		if typeof(fn) == "function" then
			fn()
		end
	end

	tbl.SetAsync = function(self, key, value, userIds, options)
		enforceKeyLimits(key)
		enforceDataLimits(value)

		if not checkRateLimit("SetAsync") then
			enqueueRequest("SetAsync")
		end
		delayWait(0.1)

		local scopedData = getScopedData(self)
		scopedData[key] = value
		mockKeyInfo[`{self.datastoreName}|{self.scope}|{key}`] =
			createMockKeyInfo(userIds, options and options:GetMetadata())
	end

	tbl.GetAsync = function(self, key): any
		if not checkRateLimit("GetAsync") then
			enqueueRequest("GetAsync")
		end
		delayWait(0.1)

		local scopedData = getScopedData(self)
		local data = scopedData[key]

		return data, mockKeyInfo[`{self.datastoreName}|{self.scope}|{key}`]
	end

	tbl.UpdateAsync = function(self, key, transformFunction): any
		if not checkRateLimit("UpdateAsync") then
			enqueueRequest("UpdateAsync")
		end
		delayWait(0.1)

		local scopedData = getScopedData(self)
		local keyInfo = mockKeyInfo[`{self.datastoreName}|{self.scope}|{key}`] or createMockKeyInfo()
		local oldScopedData = scopedData[key]
		local previousValue = oldScopedData ~= nil and Tables.copyDeep(oldScopedData)
		local thisValue = oldScopedData ~= nil and Tables.copyDeep(oldScopedData)

		local newValue, newUserIds, newMetadata = transformFunction(thisValue, keyInfo)

		if newValue ~= nil then
			if not Tables.equalsDeep(previousValue, thisValue) then
				error("DataStoreService:UpdateAsync() Data store value has changed, retrying.", 2)
			end

			enforceDataLimits(newValue)
			scopedData[key] = newValue
			if newUserIds ~= nil then
				keyInfo.userIds = newUserIds
			end
			if newMetadata ~= nil then
				keyInfo.metadata = newMetadata
			end
			keyInfo.UpdatedTime = getNow()
			return newValue, keyInfo
		end
		return scopedData[key], keyInfo
	end

	tbl.RemoveAsync = function(self, key): any
		if not checkRateLimit("RemoveAsync") then
			enqueueRequest("RemoveAsync")
		end
		delayWait(0.01)

		local scopedData = getScopedData(self)
		local data = scopedData[key]
		local keyInfo = mockKeyInfo[`{self.datastoreName}|{self.scope}|{key}`]
		scopedData[key] = nil
		return data, keyInfo
	end

	tbl._setInternalData = function(self, newData, newKeyInfo)
		mockData[self.datastoreName] = newData
		mockKeyInfo = newKeyInfo
	end

	tbl._queueError = function(_self, requestType, errorMessage)
		table.insert(queuedErrors[requestType], errorMessage)
	end

	return (tbl :: any) :: DataStoreService
end

local function createMockService()
	local tbl = {
		dataStores = {},
	}

	tbl.GetDataStore = function(self, datastoreName: string, scope: string?): any
		local store = self.dataStores[`{datastoreName}{scope or ""}`]
		if not store then
			store = createMockStore(datastoreName, scope)
			self.dataStores[`{datastoreName}{scope or ""}`] = store
		end
		return store
	end

	return tbl
end

return {
	createMockService = createMockService,
}
