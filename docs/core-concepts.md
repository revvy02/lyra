---
sidebar_position: 3
---

# Core Concepts

To effectively use Lyra, it's important to understand how it thinks about data. Let's explore the core concepts that make up the foundation of the library.

## Understanding Sessions

When a player joins your game, you need a way to work with their data. A session is Lyra's way of managing this connection between your game and a player's saved data.

Sessions work like file locks in a distributed system. When you load a player's data, Lyra establishes a session that gives your server exclusive access to that data. This is crucial in Roblox's multi-server environment - without sessions, multiple servers might try to modify the same player's data simultaneously, leading to race conditions and data corruption.

Here's how you work with sessions:

```lua
Players.PlayerAdded:Connect(function(player)
    -- Establish exclusive access to the player's data
    store:load(player):andThen(function()
        print("Session established")
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    -- Release the lock and save any pending changes
    store:unload(player)
end)
```

Loading a session is always your first step. Any attempts to access or modify data before establishing a session will fail, as Lyra needs to ensure exclusive access before allowing operations.

## Working with Data

Once you have a session, you can start working with the player's data. Lyra provides a structured way to make changes through updates.

An update is a function that receives the current data and can modify it. The function must return true to commit the changes, providing an atomic way to perform conditional updates:

```lua
store:update(player, function(data)
    if data.coins < itemPrice then
        return false -- Abort the update
    end
    
    data.coins -= itemPrice
    table.insert(data.inventory, itemId)
    return true
end)
```

This pattern enables you to encapsulate your game's logic within updates while ensuring data consistency. The update either succeeds completely or fails entirely - there's no possibility of partial changes.

## Handling Multiple Players

Sometimes you need to coordinate changes across multiple players, like in a trading system. This is where transactions come in.

A transaction lets you modify multiple players' data atomically. Either all the changes succeed, or none of them do. This is crucial for maintaining data consistency:

```lua
store:tx({player1, player2}, function(state)
    local item = table.remove(state[player1].inventory, 1)
    if not item then
        return false -- Abort the transaction
    end
    
    table.insert(state[player2].inventory, item)
    return true
end)
```

The transaction ensures the atomicity of multi-player operations. You'll never end up in a state where an item has been removed from one player but not added to another, which is essential for maintaining the integrity of your game's economy.

## Data Validation

Data validation in Lyra works through schemas. When you create a store, you define what valid data looks like:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = {
        coins = 0,
        inventory = {},
    },
    schema = function(data)
        return type(data.coins) == "number" 
            and type(data.inventory) == "table",
            "Invalid data format"
    end,
})
```

Lyra enforces this schema on every operation, creating a type-safe boundary between your game logic and your persistent storage. If an operation would result in invalid data, Lyra rejects it before it can be saved.

## Putting It All Together

These concepts - sessions, updates, transactions, and validation - form a cohesive system for managing player data. Sessions provide concurrency control, updates offer atomic operations, transactions handle multi-player interactions, and validation maintains data integrity.

By understanding these core concepts, you can build complex game systems with confidence, knowing that Lyra is handling the complexities of distributed data management.

## Next Steps

Now that you understand the core concepts, you might want to:
- Learn about [migrations](./advanced/migrations.md) for updating your data format
- Explore [debugging](./advanced/debugging.md) for troubleshooting
- See how to [handle network updates](./advanced/networking.md)
