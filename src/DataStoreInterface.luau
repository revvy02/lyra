--!strict

local Promise = require(script.Parent.Promise)
local Types = require(script.Parent.Types)

local MAX_RETRIES = 5
local RETRY_ERROR_CODES = {
	301,
	302,
	303,
	304,
	305,
	306,
	500,
	501,
	502,
	503,
	504,
	505,
}
local ERROR_RATE = 0

local DataStoreInterface: Types.DataStoreInterfaceImpl = {} :: Types.DataStoreInterfaceImpl
DataStoreInterface.__index = DataStoreInterface

function DataStoreInterface.new(dataStoreService: DataStoreService): Types.DataStoreInterface
	local self = setmetatable({
		_dataStoreService = dataStoreService,
		_dataStores = {},
	}, DataStoreInterface)
	return self
end

function DataStoreInterface:_getDataStore(scope: string): DataStore
	if not self._dataStores[scope] then
		self._dataStores[scope] = self._dataStoreService:GetDataStore(scope)
	end
	return self._dataStores[scope]
end

function DataStoreInterface:_retry(func: () -> any): Promise.TPromise<any>
	return Promise.new(function(resolve, reject)
		local lastError
		for i = 1, MAX_RETRIES do
			if i > 1 then
				local retryAfter = 2 ^ (i - 1)
				task.wait(retryAfter)
			end

			if math.random() < ERROR_RATE then
				return reject(`DataStore error: Simulated DataStore error`)
			end

			local result = table.pack(pcall(func))
			if result[1] == true then
				return resolve(table.unpack(result, 2))
			end

			local errorCode = result[2]:match("(%d+)")
			errorCode = if errorCode then tonumber(errorCode) else nil
			if errorCode ~= nil and table.find(RETRY_ERROR_CODES, errorCode) then
				lastError = result[2]
				continue
			else
				return reject(`DataStore error: {result[2]}`)
			end
		end
		return reject(`DataStore error: too many retries. Last error: {lastError}`)
	end)
end

function DataStoreInterface:getRequestBudgetForBudgetType(budgetType: Enum.DataStoreRequestType): number
	return self._dataStoreService:GetRequestBudgetForRequestType(budgetType)
end

function DataStoreInterface:get(scope: string, key: string): Promise.TPromise<(any?, DataStoreKeyInfo?)>
	local dataStore = self:_getDataStore(scope)
	return self:_retry(function()
		return dataStore:GetAsync(key, nil :: any)
	end)
end

function DataStoreInterface:set(
	scope: string,
	key: string,
	value: any,
	userIds: { number }?,
	metadata: { [string]: any }?
): Promise.TPromise<string>
	local dataStore = self:_getDataStore(scope)
	return self:_retry(function()
		local setOptions = Instance.new("DataStoreSetOptions")
		if metadata then
			setOptions:SetMetadata(metadata)
		end
		return dataStore:SetAsync(key, value, userIds, setOptions)
	end)
end

function DataStoreInterface:update(
	scope: string,
	key: string,
	transformFunction: (currentValue: any, keyInfo: DataStoreKeyInfo) -> (any, { number }?, {}?)
): Promise.TPromise<(any, DataStoreKeyInfo)>
	local dataStore = self:_getDataStore(scope)
	return self:_retry(function()
		return dataStore:UpdateAsync(key, transformFunction)
	end) :: any
end

function DataStoreInterface:remove(scope: string, key: string): Promise.TPromise<(any?, DataStoreKeyInfo?)>
	local dataStore = self:_getDataStore(scope)
	return self:_retry(function()
		return dataStore:RemoveAsync(key)
	end)
end

function DataStoreInterface:listVersions(
	scope: string,
	key: string,
	sortDirection: Enum.SortDirection?,
	minDate: number?,
	maxDate: number?,
	pageSize: number?
): Promise.TPromise<DataStoreVersionPages>
	local dataStore = self:_getDataStore(scope)
	return self:_retry(function()
		return dataStore:ListVersionsAsync(key, sortDirection, minDate, maxDate, pageSize)
	end)
end

function DataStoreInterface:getVersion(
	scope: string,
	key: string,
	version: string
): Promise.TPromise<(any?, DataStoreKeyInfo?)>
	local dataStore = self:_getDataStore(scope)
	return self:_retry(function()
		return dataStore:GetVersionAsync(key, version)
	end)
end

return DataStoreInterface
