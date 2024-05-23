local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

local PromiseQueue = {}
PromiseQueue.__index = PromiseQueue

function PromiseQueue.new()
	return setmetatable({ _queue = {} }, PromiseQueue)
end

function PromiseQueue:add(callback: () -> ()): Promise.Promise
	return Promise.new(function(resolve, reject)
		table.insert(self._queue, function()
			return Promise.try(callback):andThen(resolve, reject)
		end)
		if #self._queue == 1 then
			self:_processQueue()
		end
	end)
end

function PromiseQueue:_processQueue()
	while #self._queue > 0 do
		local item = self._queue[1]
		-- TODO: timeout to notify of deadlock?
		item():finallyCall(table.remove, self._queue, 1):await()
	end
end

-- Returns a promise that resolves when the queue is blocked by this. The
-- resolved value is a function to unblock the queue.
local function addResumableBlock(queue: PromiseQueue): Promise.TypedPromise<() -> ()>
	return Promise.new(function(resolve)
		queue:add(function()
			return Promise.new(function(resume)
				resolve(resume)
			end)
		end)
	end)
end

function PromiseQueue.multiQueueAdd(queues: { PromiseQueue }, callback: () -> ()): Promise.Promise
	return Promise.new(function(resolve, reject)
		local promises = Sift.Array.map(queues, addResumableBlock)

		Promise.all(promises):andThen(function(resumes)
			Promise.try(callback):andThen(resolve, reject):finally(function()
				for _, resume in resumes do
					resume()
				end
			end)
		end)
	end)
end

return PromiseQueue
