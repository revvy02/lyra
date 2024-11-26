--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Store = require(script.Parent.Store)
local Types = require(script.Parent.Types)

type PlayerStoreImpl<T> = {
	__index: PlayerStoreImpl<T>,
	_kickPlayer: (self: PlayerStore<T>, keyOrPlayer: string | Player, message: string) -> (),

	get: (self: PlayerStore<T>, player: Player) -> Promise.TypedPromise<T>,
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

type PlayerStoreConfig<T> = {
	name: string,
	template: T,
	schema: (value: any) -> (boolean, string?),
	migrations: { [number]: (value: any) -> any }?,
	migrateFromOtherSystem: ((key: string) -> any?)?,
	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () -> () }?,
	logCallback: ((logMessage: Types.LogMessage) -> ())?,
}

type PlayerStore<T> = typeof(setmetatable({} :: PlayerStoreProps<T>, {} :: PlayerStoreImpl<T>))

local function getUserIdKey(player: Player): string
	return tostring(player.UserId)
end

local PlayerStore: PlayerStoreImpl<any> = {} :: PlayerStoreImpl<any>
PlayerStore.__index = PlayerStore

local function createPlayerStore<T>(config: PlayerStoreConfig<T>): PlayerStore<T>
	local self: PlayerStore<T>

	local storeConfig = {
		name = config.name,
		template = config.template,
		schema = config.schema,
		migrations = config.migrations,
		migrateFromOtherSystem = config.migrateFromOtherSystem,
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

function PlayerStore:get(player: Player)
	local userIdKey = getUserIdKey(player)
	return self._store:get(userIdKey)
end

function PlayerStore:load(player: Player)
	local userIdKey = getUserIdKey(player)
	return self._store:load(userIdKey, { player.UserId }):catch(function(e)
		self:_kickPlayer(player, "DataStore load failed, please rejoin the game.")
		return Promise.reject(e)
	end)
end

function PlayerStore:unload(player: Player)
	local userIdKey = getUserIdKey(player)
	return self._store:unload(userIdKey)
end

function PlayerStore:update<T>(player: Player, transformFunction: (data: T) -> boolean)
	local userIdKey = getUserIdKey(player)
	return self._store:update(userIdKey, transformFunction)
end

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

function PlayerStore:save(player: Player)
	local userIdKey = getUserIdKey(player)
	return self._store:save(userIdKey)
end

function PlayerStore:close()
	return self._store:close()
end

return createPlayerStore
