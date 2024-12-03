---
sidebar_position: 1
---

# Introduction

Lyra makes it easy to save player data in your Roblox game. It handles all the tricky parts - data loss prevention, trading items safely, validating data formats, and smoothly updating your data structure as your game evolves.

## Features

⚔️ **Transactions** - Safe trading between players - no more item duplication bugs

🔒 **Session Locking** - Prevents multiple servers from corrupting each other's data

💎 **Auto-Sharding** - Handles large data by automatically splitting across multiple keys

🦋 **Migrations** - Update your data format without breaking existing saves

🔄 **Drop-in** - Import your existing data and switch over seamlessly

⚡ **Efficient** - Minimizes DataStore calls and bandwidth usage

👁️ **Validation** - Catches bad data before it gets saved

🎯 **Auto-Retry** - Handles DataStore errors and throttling automatically

## Importing Existing Data

When switching to Lyra, you'll want to bring your existing data:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    importLegacyData = function(key)
        local success, data = pcall(function()
            return YourCurrentSystem.getData(key)
        end)
        
        -- if something goes wrong, just error and lyra will kick the player so they can rejoin and try importing again
        if not success then
            error("Failed to reach data system")
        end
        
        -- if the player's new, return nil to use template data
        if not data then
            return nil
        end
        
        return data
    end,
})
```

:::caution
Take care implementing `importLegacyData`. Return `nil` for expected cases (like new players) to use template data. For temporary failures accessing your old system, you can `error()` which will kick the player and let them try again.
:::

## Quick Example

Here's what using Lyra looks like:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = {
        coins = 0,
        inventory = {},
    },
    schema = t.strictInterface({
        coins = t.number,
        inventory = t.table,
    }),
})

-- Load data when players join
Players.PlayerAdded:Connect(function(player)
    store:load(player):expect()
end)

-- Update data
store:update(player, function(data)
    -- Always work with the data passed to this function
    -- Don't use data from an earlier :get() call!
    data.coins += 100
    return true
end):expect()

-- Trade items safely
store:tx({player1, player2}, function(state)
    local temp = state[player1].item
    state[player1].item = state[player2].item
    state[player2].item = temp
    return true
end):expect()
```

:::warning Avoid Stale Data
Never use data from a previous `:get()` call in your updates:
```lua
-- 🚫 Don't do this:
local data = store:get(player):expect()
store:update(player, function()
    data.coins += 100 -- This data might be stale!
    return true
end):expect()

-- ✅ Do this instead:
store:update(player, function(data)
    data.coins += 100 -- This data is always current
    return true
end):expect()
```
:::

## Installation

Add to your `wally.toml`:
```toml
[dependencies]
Lyra = "paradoxum-games/lyra@0.1.0"
```

## Next Steps

- Check out [Getting Started](./getting-started.md) for a complete setup guide
- Read [Core Concepts](./core-concepts.md) to understand how Lyra works
- See the [Advanced Features](./category/advanced-features) section for migration guides and debugging tips