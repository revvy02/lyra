--[[
	@module Log

	Provides a structured logging implementation for the Lyra library.

	**Design:**
	- **Callback-based:** Instead of directly printing or sending logs, this module
	  uses a callback function (`logCallback`) provided during logger creation. This
	  allows the consuming application to decide how and where log messages are routed
	  (e.g., print to console, send to an external service, store in memory).
	- **Structured Context:** Log messages include a `context` table. Loggers can be
	  `extend`ed with additional context fields, which are automatically merged into
	  every subsequent log message created by that logger instance or its descendants.
	  This helps provide detailed, structured information for debugging and monitoring.
	- **Log Levels:** Supports standard log levels (`fatal`, `error`, `warn`, `info`,
	  `debug`, `trace`). A global log level can be set using `Log.setLevel` to filter
	  out messages below the desired severity.

	**Usage:**
	```lua
	local Log = require(script.Parent.Log)

	-- Set the global minimum log level (optional, defaults to "info")
	Log.setLevel("debug")

	-- Create a logger instance with a callback
	local myLogger = Log.createLogger(function(logMessage)
		print(`[{logMessage.level}] {logMessage.message}`, logMessage.context)
	end, { initialContext = "value" })

	-- Log messages
	myLogger:log("info", "User logged in", { userId = 123 })

	-- Create a logger with extended context
	local sessionLogger = myLogger:extend({ sessionId = "abc" })
	sessionLogger:log("debug", "Session data loaded")
	-- Output will include { initialContext = "value", sessionId = "abc", userId = 123 }
	-- if logged via myLogger, or { initialContext = "value", sessionId = "abc" }
	-- if logged via sessionLogger.
	```
]]

local Types = require(script.Parent.Types)

-- Ordered list of log levels from most severe to least severe.
local levels = {
	"fatal",
	"error",
	"warn",
	"info",
	"debug",
	"trace",
}

-- The main Log module table, holds global settings like the current log level.
local Log = {
	level = "info", -- Default global log level.
}

--[[
	Sets the global minimum log level.
	Messages with a severity lower than this level will be ignored by all loggers.
	@param level Types.LogLevel The minimum log level to allow.
	@error Throws an error if the provided level is invalid.
]]
function Log.setLevel(level: Types.LogLevel)
	if table.find(levels, level) == nil then
		error(`Invalid log level: '{level}'`)
	end
	Log.level = level
end

-- Metatable implementing the Logger methods. (Internal)
local Logger: Types.LoggerImpl = {} :: Types.LoggerImpl
Logger.__index = Logger

--[[
	Logs a message if its level is at or above the globally set log level.

	Merges the provided `context` table with the logger's persistent context
	before calling the configured `_logCallback`.

	@param level Types.LogLevel The severity level of the message.
	@param message string The log message content.
	@param context { [string]: any }? Optional additional context specific to this log call.
]]
function Logger:log(level: Types.LogLevel, message: string, context: { [string]: any }?)
	-- Filter messages based on the global log level.
	if table.find(levels, level) > table.find(levels, Log.level) then
		return
	end

	-- Merge instance context with call-specific context.
	local finalContext = table.clone(self._context)
	if context then
		for key, value in context do
			finalContext[key] = value
		end
	end

	-- Call the configured log callback within a protected call to catch errors.
	local ok, result = pcall(function()
		self._logCallback({
			level = level,
			message = message,
			context = finalContext,
		})
	end)

	if not ok then
		-- If the logging callback itself errors, print a warning.
		warn(`Error in log callback: {result}`)
	end
end

--[[
	Creates a new Logger instance that inherits the parent's callback
	but has an extended context.

	The new logger's context is a merged table containing the parent's context
	and the additional `context` provided here.

	@param context { [string]: any } The additional context fields to add.
	@return Types.Logger A new Logger instance with the extended context.
]]
function Logger:extend(context: { [string]: any }): Types.Logger
	-- Merge existing context with the new context.
	local finalContext = table.clone(self._context)
	for key, value in context do
		finalContext[key] = value
	end

	-- Create and return a new logger instance sharing the callback but with the new context.
	return setmetatable({
		_logCallback = self._logCallback,
		_context = finalContext,
	}, Logger)
end

--[[
	Factory function to create a new root Logger instance.

	@param logCallback (logMessage: Types.LogMessage) -> () The function that will be
		called for each log message that passes the level filter. This function
		receives the complete `LogMessage` object including merged context.
	@param context { [string]: any }? Optional initial context for this logger.
	@return Types.Logger A new Logger instance.
]]
function Log.createLogger(logCallback: (logMessage: Types.LogMessage) -> (), context: { [string]: any }?): Types.Logger
	return setmetatable({
		_logCallback = logCallback,
		_context = context or {}, -- Initialize with provided context or an empty table.
	}, Logger)
end

return Log
