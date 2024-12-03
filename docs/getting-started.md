---
sidebar_position: 2
---

# Getting Started

Let's get Lyra set up in your game and cover the basics of saving player data.

## Installation

Add Lyra to your `wally.toml`:

```toml
[dependencies]
Lyra = "paradoxum-games/lyra@0.1.0"
```

:::tip
If you're new to Wally, check out the [Wally installation guide](https://wally.run/install).
:::

## Importing Existing Data

If you're migrating from another data system, Lyra makes it easy to bring your existing data:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    -- Import data from your current system
    importLegacyData = function(key)
        local success, data = pcall(function()
            return DataStoreService:GetDataStore("OldData"):GetAsync(key)
        end)
        if success then
            return data
        end
        return nil -- Return nil to use template data
    end,
})
```

## Basic Setup

Here's a complete example of setting up Lyra with proper typing and error handling:

```lua
local Players = game:GetService("Players")
local Lyra = require(path.to.Lyra)

-- Define your data template
local template = {
    coins = 0,
    inventory = {},
    stats = {
        wins = 0,
        losses = 0,
        playtime = 0,
    },
}

-- Create typed schema
local schema = t.strictInterface({
    coins = t.number,
    inventory = t.table,
    stats = t.strictInterface({
        wins = t.number,
        losses = t.number,
        playtime = t.number,
    }),
})

-- Create the store
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
})

-- Set up player handling
Players.PlayerAdded:Connect(function(player)
    store:load(player):andThen(function()
        print("Data loaded for", player.Name)
    end):catch(function(err)
        warn("Failed to load data for", player.Name, "-", err)
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    store:unload(player):catch(function(err)
        warn("Failed to unload data for", player.Name, "-", err)
    end)
end)
```

## Reading Data

Lyra provides a simple way to read player data:

```lua
-- Get current data
store:get(player):andThen(function(data)
    print(player.Name, "has", data.coins, "coins")
end):catch(warn)

-- Check stats
store:get(player):andThen(function(data)
    local winRate = data.stats.wins / (data.stats.wins + data.stats.losses)
    print(player.Name, "win rate:", winRate)
end)
```

## Modifying Data

### Simple Updates

For basic changes, use `update`:

```lua
-- Add coins
store:update(player, function(data)
    data.coins += 100
    return true
end):expect()

-- Add inventory item
store:update(player, function(data)
    table.insert(data.inventory, {
        id = "sword",
        acquired = os.time(),
    })
    return true
end):expect()
```

### Conditional Updates

You can also make decisions inside updates:

```lua
-- Try to purchase an item
store:update(player, function(data)
    if data.coins < 100 then
        return false -- Abort the update
    end
    
    data.coins -= 100
    table.insert(data.inventory, "premium_sword")
    return true
end):andThen(function()
    print("Purchase successful!")
end):catch(function(err)
    if err:match("Update aborted") then
        print("Not enough coins!")
    else
        warn("Error:", err)
    end
end)
```

## Working with DataStore Limits

Lyra automatically handles many DataStore limits for you:

### Request Throttling
```lua
-- Lyra auto-retries when hitting DataStore limits
for i = 1, 100 do
    store:update(player, function(data)
        data.coins += 1
        return true
    end):expect() -- Will pace requests appropriately
end
```

### Large Data
```lua
-- Lyra automatically shards data when it gets too big
store:update(player, function(data)
    -- Even if this makes the data too large for one key,
    -- Lyra will handle it automatically
    data.replayData = hugeReplayTable
    return true
end):expect()
```

## Handling Errors

It's important to handle errors appropriately:

```lua
-- Using :expect() for critical operations
function onCriticalPurchase()
    store:update(player, grantItem):expect() -- Throws on failure
    store:save(player):expect() -- Ensures data is saved
end

-- Using :catch() for graceful fallbacks
function onOptionalFeature()
    store:update(player, updateData)
        :andThen(function()
            print("Feature success!")
        end)
        :catch(function(err)
            -- Gracefully handle failure
            print("Feature unavailable:", err)
        end)
end
```

:::tip
Use `:expect()` when the operation must succeed, and `:catch()` when you want to handle failures gracefully.
:::

## Next Steps

Now that you've got the basics down, check out:

- [Core Concepts](./core-concepts.md) for a deeper understanding
- [Data Migrations](./advanced/migrations.md) for updating data structure
- [Network Updates](./advanced/networking.md) for client synchronization
- [Debugging](./advanced/debugging.md) for troubleshooting