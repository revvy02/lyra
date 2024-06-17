type Log = {
	fatal: (message: string) -> (),
	error: (message: string) -> (),
	warn: (message: string) -> (),
	info: (message: string) -> (),
	debug: (message: string) -> (),
	trace: (message: string) -> (),
	setLevel: (level: "fatal" | "error" | "warn" | "info" | "debug" | "trace") -> (),
}

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

for _, level in levels do
	Log[level] = function(message: string)
		if table.find(levels, level) > table.find(levels, Log.level) then
			return
		end
		local formatted = `[Lyra] [{level}] {message}`
		if level == "fatal" or level == "error" then
			task.spawn(error, formatted)
		elseif level == "warn" then
			warn(formatted)
		else
			print(formatted)
		end
	end
end

function Log.setLevel(level: "fatal" | "error" | "warn" | "info" | "debug" | "trace")
	if table.find(levels, level) == nil then
		error("Invalid log level")
	end
	Log.level = level
end

return Log
