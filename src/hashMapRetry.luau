--!strict

local Promise = require(script.Parent.Promise)
local Types = require(script.Parent.Types)

local MAX_RETRIES = 5
local RETRY_ERROR_CODES = {
	"TotalRequestsOverLimit",
	"InternalError",
	"Throttled",
	"PartitionRequestsOverLimit",
	"Timeout",
}

local function hashMapRetry(func: () -> any): Types.RetryHandle<Promise.TPromise<any>>
	local cancel = false

	local handle: Types.RetryHandle<Promise.TPromise<any>> = {
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

return hashMapRetry
