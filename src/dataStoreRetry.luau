--!strict

local Promise = require(script.Parent.Promise)

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

local function dataStoreRetry<T>(func: () -> T): Promise.TPromise<T>
	return Promise.new(function(resolve, reject)
		local lastError
		for i = 1, MAX_RETRIES do
			if i > 1 then
				local retryAfter = 2 ^ (i - 1)
				task.wait(retryAfter)
			end

			local result = table.pack(pcall(func)) :: any
			if result[1] == true then
				return resolve(table.unpack(result, 2))
			end

			local errorCode = result[2]:match("(%d+)")
			errorCode = if errorCode then tonumber(errorCode) else nil
			if errorCode ~= nil and table.find(RETRY_ERROR_CODES, errorCode) then
				lastError = result[2]
				continue
			else
				return reject(result[2])
			end
		end
		return reject(`DataStore error: too many retries. Last error: {lastError}`)
	end) :: any
end

return dataStoreRetry
