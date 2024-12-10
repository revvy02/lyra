--!strict

local Players = game:GetService("Players")

local Promise = require(script.Parent.Promise)
local Store = require(script.Parent.Store)
local Types = require(script.Parent.Types)

--[=[
	A PlayerStore wraps a regular Store to provide a more convenient API for working with Player data.
	It automatically converts Players to UserId keys and handles player kicks on data errors.

	```lua
	local playerStore = PlayerStore.create({
		name = "PlayerData",
		template = {
			coins = 0,
			items = {},
		},
		schema = function(data)
			return type(data.coins) == "number" and type(data.items) == "table",
				"Invalid data format"
		end,
	})

	-- Load data when player joins
	Players.PlayerAdded:Connect(function(player)
		playerStore:load(player):andThen(function()
			print("Data loaded for", player.Name)
		end)
	end)

	-- Unload data when player leaves
	Players.PlayerRemoving:Connect(function(player)
		playerStore:unload(player)
	end)
	```

	@class PlayerStore
]=]

type PlayerStoreImpl<T> = {
	__index: PlayerStoreImpl<T>,
	_kickPlayer: (self: PlayerStore<T>, keyOrPlayer: string | Player, message: string) -> (),

	get: (self: PlayerStore<T>, player: Player) -> Promise.TPromise<T>,
	load: (self: PlayerStore<T>, player: Player) -> Promise.Promise,
	unload: (self: PlayerStore<T>, player: Player) -> Promise.Promise,
	update: (self: PlayerStore<T>, player: Player, transformFunction: (data: T) -> boolean) -> Promise.Promise,
	tx: (
		self: PlayerStore<T>,
		players: { Player },
		transformFunction: (state: { [Player]: T }) -> boolean
	) -> Promise.Promise,
	save: (self: PlayerStore<T>, player: Player) -> Promise.Promise,
	close: (self: PlayerStore<T>) -> Promise.Promise,
}

type PlayerStoreProps<T> = {
	_store: Store.Store<T>,
}

--[=[
	Configuration for creating a new Store.

	@interface PlayerStoreConfig
	.name string -- The name of the store
	.template T -- The template data for new keys
	.schema (value: any) -> (boolean, string?) -- A function to validate data
	.migrationSteps { MigrationStep }? -- Optional migration steps
	.importLegacyData ((key: string) -> any?)? -- Optional function to import legacy data
	.changedCallbacks { (key: string, newData: T, oldData: T?) -> () -> () }? -- Optional callbacks for data changes
	.logCallback ((logMessage: LogMessage) -> ())? -- Optional callback for log messages

	@within PlayerStore
]=]
type PlayerStoreConfig<T> = {
	name: string,
	template: T,
	schema: (value: any) -> (boolean, string?),
	migrationSteps: { Types.MigrationStep }?,
	importLegacyData: ((key: string) -> any?)?,
	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () -> () }?,
	logCallback: ((logMessage: Types.LogMessage) -> ())?,
}

type PlayerStore<T> = typeof(setmetatable({} :: PlayerStoreProps<T>, {} :: PlayerStoreImpl<T>))

local function getUserIdKey(player: Player): string
	return tostring(player.UserId)
end

local PlayerStore: PlayerStoreImpl<any> = {} :: PlayerStoreImpl<any>
PlayerStore.__index = PlayerStore

--[=[
	Creates a new PlayerStore with the given configuration.
	Configuration is similar to Store.createStore, but automatically adds player kick handling.

	```lua
	local playerStore = PlayerStore.create({
		name = "PlayerData",
		template = { coins = 0 },
		schema = function(data)
			return type(data.coins) == "number", "coins must be a number"
		end,

		-- Optional: Runs whenever data changes
		changedCallbacks = {
			function(key, newData, oldData)
				print(key, "changed from", oldData.coins, "to", newData.coins)
			end,
		},
	})
	```

	Players will be automatically kicked with an error message if:
	- Their data fails to load
	- The DataStore lock is lost during their session

	@param config PlayerStoreConfig<T> -- Configuration for the store
	@return PlayerStore<T>
	@within PlayerStore
	@function create
]=]
local function createPlayerStore<T>(config: PlayerStoreConfig<T>): PlayerStore<T>
	local self: PlayerStore<T>

	local storeConfig: Store.StoreConfig<T> = {
		name = config.name,
		template = config.template,
		schema = config.schema,
		migrationSteps = config.migrationSteps,
		importLegacyData = config.importLegacyData,
		changedCallbacks = config.changedCallbacks,
		logCallback = config.logCallback,
		onLockLost = function(key: string)
			self:_kickPlayer(key, "DataStore lock lost, please rejoin the game.")
		end,
	}

	local store = Store.createStore(storeConfig)
	self = setmetatable({ _store = store }, PlayerStore)
	return self
end

--[=[
	Internal helper to kick players when data errors occur.

	@within PlayerStore
	@private
]=]
function PlayerStore:_kickPlayer(keyOrPlayer: string | Player, message: string): ()
	if typeof(keyOrPlayer) ~= "string" then
		keyOrPlayer:Kick(message)
	else
		local player = Players:GetPlayerByUserId(tonumber(keyOrPlayer))
		if player ~= nil then
			player:Kick(message)
		end
	end
end

--[=[
	Gets the current data for the given player.

	```lua
	playerStore:get(player):andThen(function(data)
		print(player.Name, "has", data.coins, "coins")
	end)
	```

	@error "Key not loaded" -- The player's data hasn't been loaded
	@error "Store is closed" -- The store has been closed
	@return Promise<T> -- Resolves with the player's data
	@within PlayerStore
]=]
function PlayerStore:get(player: Player)
	local userIdKey = getUserIdKey(player)
	return self._store:get(userIdKey)
end

--[=[
	Loads data for the given player. Must be called before using other methods.

	```lua
	playerStore:load(player):andThen(function()
		print("Data loaded for", player.Name)
	end)
	```

	:::caution
	If loading fails, the player will be kicked from the game.
	:::

	@error "Load already in progress" -- Another load is in progress for this player
	@error "Store is closed" -- The store has been closed
	@return Promise -- Resolves when data is loaded
	@within PlayerStore
]=]
function PlayerStore:load(player: Player)
	local userIdKey = getUserIdKey(player)
	return self._store:load(userIdKey, { player.UserId }):catch(function(e)
		self:_kickPlayer(player, "DataStore load failed, please rejoin the game.")
		return Promise.reject(e)
	end)
end

--[=[
	Unloads data for the given player.

	```lua
	playerStore:unload(player):andThen(function()
		print("Data unloaded for", player.Name)
	end)
	```

	@error "Store is closed" -- The store has been closed
	@return Promise -- Resolves when data is unloaded
	@within PlayerStore
]=]
function PlayerStore:unload(player: Player)
	local userIdKey = getUserIdKey(player)
	return self._store:unload(userIdKey)
end

--[=[
	Updates data for the given player using a transform function.
	The transform function must return true to commit changes, or false to abort.

	```lua
	playerStore:update(player, function(data)
		if data.coins < 100 then
			data.coins += 50
			return true -- Commit changes
		end
		return false -- Don't commit changes
	end)
	```

	@error "Key not loaded" -- The player's data hasn't been loaded
	@error "Store is closed" -- The store has been closed
	@error "Schema validation failed" -- The transformed data failed schema validation
	@return Promise -- Resolves when the update is complete
	@within PlayerStore
]=]
function PlayerStore:update<T>(player: Player, transformFunction: (data: T) -> boolean)
	local userIdKey = getUserIdKey(player)
	return self._store:update(userIdKey, transformFunction)
end

--[=[
	Performs a transaction across multiple players' data atomically.
	All players' data must be loaded first. Either all changes apply or none do.

	```lua
	playerStore:tx({player1, player2}, function(state)
		-- Transfer coins between players
		if state[player1].coins >= 100 then
			state[player1].coins -= 100
			state[player2].coins += 100
			return true -- Commit transaction
		end
		return false -- Abort transaction
	end)
	```

	@error "Key not loaded" -- One or more players' data hasn't been loaded
	@error "Store is closed" -- The store has been closed
	@error "Schema validation failed" -- The transformed data failed schema validation
	@return Promise -- Resolves when the transaction is complete
	@within PlayerStore
]=]
function PlayerStore:tx<T>(players: { Player }, transformFunction: (state: { [Player]: T }) -> boolean)
	local userIdKeys = table.create(#players)
	local userIdKeyToPlayer = {}
	for i, player in players do
		local key = getUserIdKey(player)
		userIdKeys[i] = key
		userIdKeyToPlayer[key] = player
	end

	local function wrapped(state: { [string]: any }): boolean
		local userIdState = {}
		for key, value in state do
			local player = userIdKeyToPlayer[key]
			userIdState[player] = value
		end

		local success = transformFunction(userIdState)
		if success == false then
			return false
		end

		for key in state do
			state[key] = nil
		end

		for playerVariant, value in userIdState do
			local stringKey = getUserIdKey(playerVariant)
			state[stringKey] = value
		end

		return success
	end

	return self._store:tx(userIdKeys, wrapped)
end

--[=[
	Forces an immediate save of the given player's data.

	:::info
	Data is automatically saved periodically, so manual saves are usually unnecessary.
	:::

	@error "Key not loaded" -- The player's data hasn't been loaded
	@error "Store is closed" -- The store has been closed
	@return Promise -- Resolves when the save is complete
	@within PlayerStore
]=]
function PlayerStore:save(player: Player)
	local userIdKey = getUserIdKey(player)
	return self._store:save(userIdKey)
end

--[=[
	Closes the store and unloads all active sessions.
	The store cannot be used after closing.

	@return Promise -- Resolves when the store is closed
	@within PlayerStore
]=]
function PlayerStore:close()
	return self._store:close()
end

return createPlayerStore
