---
sidebar_position: 3
---

# Core Concepts

Lyra manages data through sessions and provides guarantees about how operations execute.

## Sessions

Every player's data is managed through a session. Always load when they join and unload when they leave:

```lua
Players.PlayerAdded:Connect(function(player)
    store:load(player):expect()
end)

Players.PlayerRemoving:Connect(function(player)
    store:unload(player):expect()
end)
```

:::caution
Always load before performing operations. Attempting operations on an unloaded key will error with "Key not loaded".
:::

## Operation Order

Operations in Lyra queue up and execute in order:

```lua
store:save(player)     -- 1st
store:tx({player}, fn) -- 2nd
store:save(player)     -- 3rd
```

However, `update` calls are special - they execute immediately if no transaction is in progress:

```lua
store:update(player, fn) -- Runs right away if no active transaction
```

This optimization gives you fast writes for common operations while maintaining data safety.

## Transactions

When you need to modify multiple players' data atomically, use transactions:

```lua
store:tx({player1, player2}, function(state)
    state[player1].coins -= 100
    state[player2].coins += 100
    return true
end):expect()
```

During a transaction:
- All keys must be loaded first
- No other transactions can run on those keys
- Either all changes apply or none do
- Updates on those keys wait for the transaction to finish

:::warning
Don't modify the state keys table in a transaction (adding/removing keys). Only modify the data within each state entry.
:::

## Data Validation

Lyra uses schemas to validate your data:

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

Validation happens:
- When loading data
- After updates and transactions
- Before saving to DataStore

## See Also

- [Getting Started](./getting-started.md) for basic setup
- [Migrations](./advanced/migrations.md) for updating data formats
- [Debugging](./advanced/debugging.md) for troubleshooting