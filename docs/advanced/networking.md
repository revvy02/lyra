---
sidebar_position: 2
---

# Network Updates

Lyra provides `changedCallbacks` to help you keep clients in sync with data changes.

## Basic Usage

```lua
local function propagateChanges(key: string, newData, oldData)
    local player = Players:GetPlayerByUserId(tonumber(key))
    if player then
        Network.PlayerData:FireClient(player, {
            coins = newData.coins,
            inventory = newData.inventory,
        })
    end
end

local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    changedCallbacks = { propagateChanges },
})
```

## Multiple Callbacks

You can register multiple callbacks for different purposes:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    changedCallbacks = { 
        -- Update clients
        propagateChanges,
        -- Log changes
        function(key, newData, oldData)
            print(key, "data changed")
        end,
    },
})
```

## See Also

- [Core Concepts](../core-concepts.md) for understanding data management
- [Getting Started](../getting-started.md) for basic Lyra setup