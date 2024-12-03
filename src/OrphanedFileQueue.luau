--!strict

local Tables = require(script.Parent.Tables)
local Types = require(script.Parent.Types)

local OrphanedFileQueue: Types.OrphanedFileQueueImpl = {} :: Types.OrphanedFileQueueImpl
OrphanedFileQueue.__index = OrphanedFileQueue

function OrphanedFileQueue.new(): Types.OrphanedFileQueue
	return setmetatable({
		queue = {},
	}, OrphanedFileQueue) :: Types.OrphanedFileQueue
end

function OrphanedFileQueue:markFile(key: string, file: Types.File)
	for _, entry in self.queue do
		if Tables.equalsDeep(entry.file, file) then
			return
		end
	end

	table.insert(self.queue, { key = key, file = file, beingProcessed = false })

	if #self.queue == 1 then
		task.spawn(function()
			self:_processQueueItems()
		end)
	end
end

function OrphanedFileQueue:markFiles(key: string, files: { Types.File })
	for _, file in files do
		self:markFile(key, file)
	end
end

function OrphanedFileQueue:_processQueueItems()
	if self.processQueueItem == nil then
		error("processQueueItem not assigned")
	end

	while #self.queue > 0 do
		local unprocessedEntry
		for _, entry in self.queue do
			if not entry.beingProcessed then
				unprocessedEntry = entry
				break
			end
		end

		local wasProcessed = self.processQueueItem(unprocessedEntry)
		if wasProcessed then
			local idx = table.find(self.queue, unprocessedEntry)
			if idx then
				table.remove(self.queue, idx)
			end
		end

		task.wait(0.1)
	end
end

return OrphanedFileQueue
