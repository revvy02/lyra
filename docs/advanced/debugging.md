---
sidebar_position: 3
---

# Debugging

Lyra provides logging capabilities through its `logCallback` to help you track operations and errors.

## Basic Setup

```lua
local function handleLogs(message: LogMessage)
    if message.level == "error" then
        Analytics:captureError(message.message)
    elseif message.level == "warn" then
        Analytics:captureWarning(message.message)
    end
end

local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    logCallback = handleLogs,
})
```

## Log Levels

Lyra uses the following log levels:
- `fatal` - Unrecoverable errors
- `error` - Operation failures
- `warn` - Potential issues
- `info` - Important operations
- `debug` - Detailed operation info
- `trace` - Very detailed debugging info

## Development vs Production

You might want different logging behavior in different environments:

```lua
local function createLogger()
    if game:GetService("RunService"):IsStudio() then
        -- Detailed logging in Studio
        return function(message)
            print(`[Lyra][{message.level}] {message.message}`)
            if message.context then
                print("Context:", message.context)
            end
        end
    else
        -- Only log important things in production
        return function(message)
            if message.level == "error" or message.level == "fatal" then
                Analytics:captureError(message.message, message.context)
            end
        end
    end
end

local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    logCallback = createLogger(),
})
```

## See Also

- [Core Concepts](../core-concepts.md) for understanding operations
- [Getting Started](../getting-started.md) for basic setup