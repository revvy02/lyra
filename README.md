<p align="center">
  <h1 align="center">Lyra</h1>
  <p align="center">
    Safe and simple data persistence for Roblox games
    <br />
    <a href="https://github.com/paradoxum-games/lyra/tree/main/docs"><strong>Documentation »</strong></a>
  </p>
</p>

<div align="center">

![GitHub License](https://img.shields.io/github/license/paradoxum-games/lyra?style=for-the-badge)
[![Wally](https://img.shields.io/badge/Wally-Package-orange?style=for-the-badge)](https://wally.run/package/paradoxum-games/lyra)

</div>

A library that handles all the tricky parts of saving player data: retries, conflicts, validation, and trading. Built to prevent data loss and duplication bugs.

## Features

⚔️ **Transactions** - Safe trading between players - no more item duplication bugs

🔒 **Session Locking** - Prevents multiple servers from corrupting each other's data

💎 **Auto-Sharding** - Handles large data by automatically splitting across multiple keys

🦋 **Migrations** - Update your data format without breaking existing saves

🔄 **Drop-in** - Import your existing data and switch over seamlessly

## Quick Start

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

-- Update data safely
store:update(player, function(data)
    data.coins += 100
    return true
end):expect()
```

## Installation

Add to your `wally.toml`:
```toml
[dependencies]
Lyra = "paradoxum-games/lyra@0.1.0"
```

Check out the [documentation](https://github.com/paradoxum-games/lyra/tree/main/docs) for guides, examples, and API reference.
