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

## Basic Setup

Here's how to set up Lyra with a simple data structure:

```lua
local Players = game:GetService("Players")
local Lyra = require(path.to.Lyra)

-- Define your data template
local template = {
    coins = 0,
    inventory = {},
}

-- Create schema to validate data
local schema = t.strictInterface({
    coins = t.number,
    inventory = t.table,
})

-- Create the store
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
})

-- Load data when players join
Players.PlayerAdded:Connect(function(player)
    store:load(player):expect()
end)

-- Save and clean up when they leave
Players.PlayerRemoving:Connect(function(player)
    store:unload(player):expect()
end)
```

## Working with Data

### Reading Data

You can read player data, but remember that it might change between reads:

```lua
store:get(player):andThen(function(data)
    -- ⚠️ Only use this data for reading
    -- Don't save it for later use
    print(`{player.Name} has {data.coins} coins`)
end)
```

### Modifying Data

Always modify data through update functions:

```lua
-- Simple update
store:update(player, function(data)
    data.coins += 100
    return true
end)

-- Conditional update
store:update(player, function(data)
    if data.coins < itemPrice then
        return false -- Abort the update
    end
    
    data.coins -= itemPrice
    table.insert(data.inventory, itemId)
    return true
end)
```

### Trading Between Players

Use transactions for operations involving multiple players:

```lua
store:tx({player1, player2}, function(state)
    -- Transfer coins
    if state[player1].coins < amount then
        return false -- Abort if not enough coins
    end
    
    state[player1].coins -= amount
    state[player2].coins += amount
    return true
end)
```

## Error Handling

Lyra operations return promises that you can handle in different ways:

```lua
-- Using :expect(), which will throw an error if the operation fails
store:update(player, function(data)
    data.coins -= itemPrice
    data.inventory.weapon = "starter_sword"
    return true
end):expect()

-- Using :andThen() and :catch()
store:update(player, function(data)
    data.coins -= itemPrice
    data.inventory.weapon = "starter_sword"
    return true
end):andThen(function()
    print("Purchase successful!")
end):catch(function(err)
    print(`Purchase failed: {err}`)
end)
```

## Importing Existing Data

If you're migrating from another system, you can import your existing data:

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

## Next Steps

Now that you've got the basics down, check out:

- [Core Concepts](./core-concepts.md) for a deeper understanding
- [Data Migrations](./advanced/migrations.md) for updating data structure
- [Network Updates](./advanced/networking.md) for client synchronization
- [Debugging](./advanced/debugging.md) for troubleshooting
