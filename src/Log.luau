local Types = require(script.Parent.Types)

export type Level = "fatal" | "error" | "warn" | "info" | "debug" | "trace"
local levels = {
	"fatal",
	"error",
	"warn",
	"info",
	"debug",
	"trace",
}

local Log = {
	level = "info",
}

function Log.setLevel(level: Level)
	if table.find(levels, level) == nil then
		error("Invalid log level")
	end
	Log.level = level
end

function Log.filterCallback<T>(callback: ((logMessage: Types.LogMessage) -> ())?): (level: Level, message: string) -> ()
	if callback == nil then
		return function() end
	end
	return function(level: Level, message: string)
		if table.find(levels, level) > table.find(levels, Log.level) then
			return
		end

		callback({
			level = level,
			message = message,
		})
	end
end

return Log
