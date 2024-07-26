--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local Store = require(script.Parent.Store)
local mapKeys = require(script.Parent.mapKeys)

type PlayerStoreImpl<T> = {
	__index: PlayerStoreImpl<T>,
	get: (self: PlayerStore<T>, userId: number) -> Promise.TypedPromise<T>,
	load: (self: PlayerStore<T>, userId: number) -> Promise.Promise,
	unload: (self: PlayerStore<T>, userId: number) -> Promise.Promise,
	update: (self: PlayerStore<T>, userId: number, transformFunction: (data: T) -> boolean) -> Promise.Promise,
	tx: (
		self: PlayerStore<T>,
		userIds: { number },
		transformFunction: (state: { [number]: T }) -> boolean
	) -> Promise.Promise,
	save: (self: PlayerStore<T>, userId: number) -> Promise.Promise,
	close: (self: PlayerStore<T>) -> Promise.Promise,
}

type PlayerStoreProps<T> = {
	_store: Store.Store<T>,
}

type PlayerStore<T> = typeof(setmetatable({} :: PlayerStoreProps<T>, {} :: PlayerStoreImpl<T>))

local function assertUserId(userId: number): string
	assert(typeof(userId) == "number", "userId must be a number")

	local userIdKey = tostring(userId)
	assert(userIdKey ~= nil, "userId must be a valid number")
	assert(string.match(userIdKey, "^%-?%d+$"), "userId must be an integer")

	return userIdKey
end

local PlayerStore: PlayerStoreImpl<any> = {} :: PlayerStoreImpl<any>
PlayerStore.__index = PlayerStore

local function createPlayerStore<T>(config: Store.StoreConfig<T>): PlayerStore<T>
	local store = Store.createStore(config)
	return setmetatable({ _store = store }, PlayerStore)
end

function PlayerStore:get(userId: number)
	local userIdKey = assertUserId(userId)
	return self._store:get(userIdKey)
end

function PlayerStore:load(userId: number)
	local userIdKey = assertUserId(userId)
	return self._store:load(userIdKey)
end

function PlayerStore:unload(userId: number)
	local userIdKey = assertUserId(userId)
	return self._store:unload(userIdKey)
end

function PlayerStore:update<T>(userId: number, transformFunction: (data: T) -> boolean)
	local userIdKey = assertUserId(userId)
	return self._store:update(userIdKey, transformFunction)
end

function PlayerStore:tx<T>(userIds: { number }, transformFunction: (state: { [number]: T }) -> boolean)
	local userIdKeys = Sift.Array.map(userIds, assertUserId)

	local function wrapped(state)
		local userIdState: { [number]: any } = mapKeys(state, tonumber) :: any

		local success = transformFunction(userIdState)
		if success == false then
			return false
		end

		for key in state do
			state[key] = nil
		end

		for userIdKey, value in userIdState do
			local stringKey = assertUserId(userIdKey)
			state[stringKey] = value
		end

		return success
	end

	return self._store:tx(userIdKeys, wrapped)
end

function PlayerStore:save(userId: number)
	local userIdKey = assertUserId(userId)
	return self._store:save(userIdKey)
end

function PlayerStore:close()
	return self._store:close()
end

return createPlayerStore
