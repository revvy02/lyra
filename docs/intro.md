---
sidebar_position: 1
---

# Introduction

Lyra makes it easy to save player data in your Roblox game. It handles all the tricky parts - data loss prevention, trading items safely, validating data formats, and smoothly updating your data structure as your game evolves.

## Features

**Data Safety**
- 🔒 **Session Locking** - Prevents multiple servers from corrupting each other's data
- ⚔️ **Transactions** - Safe trading between players - no more item duplication bugs
- 👁️ **Validation** - Catches bad data before it gets saved

**Performance**
- 💎 **Auto-Sharding** - Handles large data by automatically splitting across multiple keys
- ⚡ **Efficient** - Minimizes DataStore calls and bandwidth usage
- 🎯 **Auto-Retry** - Handles DataStore errors and throttling automatically

**Development**
- 🦋 **Migrations** - Update your data format without breaking existing saves
- 🔄 **Drop-in** - Import your existing data and switch over seamlessly

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

-- Safe updates with validation
store:update(player, function(data)
    if data.coins < itemPrice then
        return false -- Abort if can't afford
    end
    data.coins -= itemPrice
    table.insert(data.inventory, itemId)
    return true
end):expect()

-- Atomic trades between players
store:tx({player1, player2}, function(state)
    -- Either both changes happen or neither does
    state[player1].coins -= 100
    state[player2].coins += 100
    return true
end):expect()
```

:::warning Avoid Stale Data
Always modify data through update functions. Never use data from a previous `:get()` call:
```lua
-- 🚫 Don't do this:
local oldData = store:get(player):expect()
store:update(player, function(newData)
    if not oldData.hasGift then -- This data might be stale!
        return false
    end
    newData.coins += 500
    newData.hasGift = false
    return true
end)

-- ✅ Do this instead:
store:update(player, function(data)
    data.coins += 100 -- This data is always current
    return true
end)
```
:::

## Importing Existing Data

When switching to Lyra, you can bring your existing data:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    importLegacyData = function(key)
        local success, data = pcall(function()
            return YourCurrentSystem.getData(key)
        end)
        
        if not success then
            error("Failed to reach data system") -- Player will be kicked and can retry
        end

        if data ~= nil then
            return data -- Return existing data to import
        end
        
        return nil -- Return nil for new players to use template
    end,
})
```

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
