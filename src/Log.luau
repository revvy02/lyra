--!strict

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

type LoggerImpl = {
	__index: LoggerImpl,

	log: (self: Logger, level: Level, message: string, context: { [string]: any }?) -> (),
	extend: (self: Logger, context: { [string]: any }) -> Logger,
}

type LoggerProps = {
	_logCallback: (logMessage: Types.LogMessage) -> (),
	_context: { [string]: any },
}

type Logger = typeof(setmetatable({} :: LoggerProps, {} :: LoggerImpl))

local Logger: LoggerImpl = {} :: LoggerImpl
Logger.__index = Logger

function Logger:log(level: Level, message: string, context: { [string]: any }?)
	if table.find(levels, level) > table.find(levels, Log.level) then
		return
	end

	local finalContext = table.clone(self._context)
	if context then
		for key, value in context do
			finalContext[key] = value
		end
	end

	self._logCallback({
		level = level,
		message = message,
		context = finalContext,
	})
end

function Logger:extend(context: { [string]: any }): Logger
	local finalContext = table.clone(self._context)
	for key, value in context do
		finalContext[key] = value
	end

	return setmetatable({
		_logCallback = self._logCallback,
		_context = finalContext,
	}, Logger)
end

function Log.createLogger(logCallback: (logMessage: Types.LogMessage) -> (), context: { [string]: any }?): Logger
	return setmetatable({
		_logCallback = logCallback,
		_context = context or {},
	}, Logger)
end

return Log
