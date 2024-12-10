---
sidebar_position: 1
---

# Data Migrations

As your game evolves, you'll need to update your data format - adding new fields, renaming existing ones, or restructuring data entirely. Lyra's migration system helps you transform existing player data safely and automatically.

:::danger Never Change Published Migrations
Once your game is live, never:
- Change the content of existing migrations
- Reorder existing migrations
- Remove existing migrations

Lyra tracks which migrations have run for each player. Changing existing migrations means some players will run different versions of the same migration, corrupting their data. Always add new migrations instead of modifying existing ones.
:::

## How Migrations Work

When a player's data is loaded, Lyra:
1. Checks which migrations have already run for this player
2. Runs any new migrations in order
3. Records which migrations were applied
4. Validates the final data against your schema

This means each migration runs exactly once per player, even if they join multiple times or on different servers.

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

:::danger Migration Names Are Permanent
Migration names (like "add_player_settings") are permanent and help Lyra track which migrations have run. Choose descriptive names that indicate what the migration does, as you can't change them later.
:::

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
        }
        return data
    end)
    :finalize()
```

:::danger Migration Order Is Critical
Migrations always run in the order they're defined. This order becomes permanent once published - you can't change it later. If a new migration needs data from an older one, add it after the existing migrations.
:::

## Best Practices

When working with migrations:

1. **Plan carefully** - Once published, migrations can't be changed
2. **Keep migrations simple** - One logical change per step
3. **Test thoroughly** - Migrations run once and can't be undone

## See Also

- [Getting Started](../getting-started.md) for basic Lyra usage
- [Debugging](./debugging.md) for troubleshooting migrations
- [Core Concepts](../core-concepts.md) for understanding how Lyra works
