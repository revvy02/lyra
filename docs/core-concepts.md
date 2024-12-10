---
sidebar_position: 3
---

# Core Concepts

To effectively use Lyra, it's important to understand how it thinks about data. Let's explore the core concepts that make up the foundation of the library.

## Understanding Sessions

When a player joins your game, you need a way to work with their data. A session is Lyra's way of managing this connection between your game and a player's saved data.

Sessions utilize 'session locking' to keep data safe. When you load a player's data, Lyra 'locks' it, which gives your server exclusive access to that data. This is crucial - without session locking, multiple servers might try to modify the same player's data simultaneously, leading to race conditions and lost data.

Here's how you work with sessions:

```lua
Players.PlayerAdded:Connect(function(player)
    -- Establish exclusive access to the player's data
    store:load(player):expect()
end)

Players.PlayerRemoving:Connect(function(player)
    -- Release the lock and save any pending changes
    store:unload(player)
end)
```

Loading a session is always your first step. Any attempts to access or modify data before establishing a session will fail, as Lyra needs to ensure exclusive access before allowing operations.

## Working with Data

Once you have a session, you can start working with the player's data. Lyra provides a structured way to make changes through updates.

An update is a function that receives the current data and can modify it mutably. The function must return true to commit the changes, providing an atomic way to perform conditional updates:

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

:::warning Don't Yield!
Lyra enforces that updates are synchronous and non-blocking - if you yield inside the update function, it will error and abort the operation.
:::

## Handling Multiple Players

Sometimes you need to coordinate changes across multiple players, like in a trading system. 

If you update each player individually, there's no guarantee that one player's changes will succeed while the other's fail - imagine a server crashing at exactly the right moment.

This is where transactions come in.

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
    schema = t.strictInterface({
        coins = t.number,
        inventory = t.table,
    }),
})
```

Lyra enforces this schema on every operation, creating a safe boundary between your game logic and DataStores. If an operation would result in invalid data, Lyra rejects it before it can be saved.

:::tip
We recommend using ['t', a Runtime Typechecker for Roblox](https://github.com/osyrisrblx/t) for defining schemas!
:::

## Next Steps

Now that you understand the core concepts, you might want to:
- Learn about [migrations](./advanced/migrations.md) for updating your data format
- Explore [debugging](./advanced/debugging.md) for troubleshooting
- See how to [handle network updates](./advanced/networking.md)
