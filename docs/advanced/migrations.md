---
sidebar_position: 1
---

# Data Migrations

Data formats evolve as your game grows. You might need to add new fields, rename existing ones, or completely restructure your data. Lyra's migration system helps you transform existing player data safely and automatically.

## Overview

Migrations in Lyra:
- Run automatically when loading player data
- Execute only once per player
- Run in the order you define them
- Can add fields, remove fields, or transform data structure
- Validate data after each step

## Basic Migrations

The simplest migration is adding new fields:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    migrationSteps = Lyra.Migration.new()
        :fields("add_player_settings", {
            settings = {
                music = true,
                sfx = true,
            }
        })
        :finalize(),
})
```

This adds a `settings` table to any player data that doesn't have it.

## Transform Steps

For more complex changes, use `transform` steps:

```lua
migrationSteps = Lyra.Migration.new()
    :transform("inventory_to_items", function(data)
        -- Convert simple inventory list to detailed items
        data.items = {}
        for item in data.inventory do
            table.insert(data.items, {
                id = item,
                acquired = os.time(),
                metadata = {},
            })
        end
        data.inventory = nil
        return data
    end)
    :finalize()
```

## Multiple Steps

You can chain multiple migration steps:

```lua
migrationSteps = Lyra.Migration.new()
    -- Add new currency
    :fields("add_gems", {
        gems = 0,
    })
    -- Restructure inventory
    :transform("inventory_v2", function(data)
        data.inventory = {
            items = data.inventory,
            maxSlots = 20,
            version = 2,
        }
        return data
    end)
    -- Add achievement tracking
    :fields("add_achievements", {
        achievements = {},
        lastAchievementAt = 0,
    })
    :finalize()
```

:::tip Order Matters
Migration steps run in the order you define them. If one step depends on data from another, make sure they're in the right order!
:::

## Testing Migrations

Before deploying migrations to production, you should test them thoroughly. Here's a testing strategy:

1. Create test data in the old format
2. Run migrations
3. Verify the new format

```lua
local function testMigrations()
    -- Old data format
    local oldData = {
        coins = 100,
        inventory = {"sword", "shield"},
    }

    -- Create test store
    local store = Lyra.createPlayerStore({
        name = "TestStore",
        template = template,
        schema = schema,
        migrationSteps = yourMigrations,
    })

    -- Run migrations on test data
    local newData = store:_runMigrations(oldData)
    
    -- Verify new format
    assert(type(newData.items) == "table", "Items should be a table")
    assert(newData.items[1].id == "sword", "First item should be sword")
    assert(type(newData.items[1].acquired) == "number", "Acquired time should be number")
end
```

## Best Practices

When working with migrations:

1. **Never modify existing migrations** - Add new ones instead
2. **Keep migrations simple** - One logical change per step
3. **Handle edge cases** - Check if fields exist before accessing them
4. **Test thoroughly** - Migrations run once and can't be undone
5. **Back up data** - Consider backing up before major migrations

## Common Patterns

### Adding New Systems

When adding new game systems, start with sensible defaults:

```lua
:fields("add_crafting", {
    craftingLevel = 1,
    recipes = {},
    materialsInventory = {},
    currentProject = nil,
})
```

### Data Structure Changes

When changing how data is organized:

```lua
:transform("normalize_inventory", function(data)
    -- Convert from array to dictionary for faster lookups
    local newInventory = {}
    for _, item in data.inventory do
        newInventory[item.id] = item
    end
    data.inventory = newInventory
    return data
end)
```

### Calculated Fields

Add fields based on existing data:

```lua
:transform("calculate_total_value", function(data)
    local total = 0
    for _, item in data.inventory do
        total += ItemValues[item.id] or 0
    end
    data.inventoryValue = total
    return data
end)
```

## See Also

- [Getting Started](../getting-started.md) for basic Lyra usage
- [Debugging](./debugging.md) for troubleshooting migrations
- [Core Concepts](../core-concepts.md) for understanding how Lyra works