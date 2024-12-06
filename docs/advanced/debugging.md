---
sidebar_position: 3
---

# Debugging

Lyra provides detailed logging to help you understand what's happening with your data and diagnose issues. You can access these logs through the `logCallback` option.

## Understanding Logs

Each log message contains:
- A severity level
- A descriptive message
- Optional context with additional details

Here's a basic setup that prints all logs:

```lua
local function handleLogs(message)
    print(`[Lyra][{message.level}] {message.message}`)
    
    if message.context then
        -- Context contains relevant data like keys, session info, etc.
        print("Context:", message.context)
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

Lyra uses different levels to categorize logs:

```lua
local function handleLogs(message)
    -- Handle based on severity
    if message.level == "fatal" then
        -- Unrecoverable errors (e.g., corrupted data)
        warn("FATAL:", message.message)
        
    elseif message.level == "error" then
        -- Operation failures (e.g., update failed)
        warn("Error:", message.message)
        
    elseif message.level == "warn" then
        -- Potential issues (e.g., slow operations)
        warn("Warning:", message.message)
        
    elseif message.level == "info" then
        -- Important operations (e.g., session started)
        print("Info:", message.message)
        
    elseif message.level == "debug" then
        -- Detailed operation info
        print("Debug:", message.message)
        
    elseif message.level == "trace" then
        -- Very detailed debugging info
        print("Trace:", message.message)
    end
end
```

## Development Mode

You often want more detailed logs in Studio:

```lua
local RunService = game:GetService("RunService")

local function createLogger()
    if RunService:IsStudio() then
        -- Show all logs in Studio
        return function(message)
            print(`[Lyra][{message.level}] {message.message}`)
            if message.context then
                print("Context:", message.context)
            end
        end
    else
        -- Only show errors in production
        return function(message)
            if message.level == "error" or message.level == "fatal" then
                warn(`[Lyra] {message.message}`)
            end
        end
    end
end

local store = Lyra.createPlayerStore({
    logCallback = createLogger(),
})
```

:::tip
The context object often contains useful debugging information like session IDs, keys being operated on, and timing data.
:::

## See Also

- [Core Concepts](../core-concepts.md) for understanding operations
- [Getting Started](../getting-started.md) for basic setup
