--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local Store = require(script.Parent.Store)
local mapKeys = require(script.Parent.mapKeys)

type PlayerStoreImpl<T> = {
	__index: PlayerStoreImpl<T>,
	get: (self: PlayerStore<T>, userId: number) -> Promise.TypedPromise<T>,
	lock: (self: PlayerStore<T>, userId: number) -> Promise.Promise,
	unlock: (self: PlayerStore<T>, userId: number) -> Promise.Promise,
	update: (self: PlayerStore<T>, userId: number, transformFunction: (data: T) -> T?) -> Promise.Promise,
	tx: (
		self: PlayerStore<T>,
		userIds: { number },
		transformFunction: (state: { [number]: T }) -> { [number]: T }?
	) -> Promise.Promise,
	save: (self: PlayerStore<T>, userId: number) -> Promise.Promise,
}

type PlayerStoreProps<T> = {
	_store: Store.Store<T>,
}

type PlayerStore<T> = typeof(setmetatable({} :: PlayerStoreProps<T>, {} :: PlayerStoreImpl<T>))

local function assertUserId(userId: number): string
	local userIdKey = tostring(userId)

	assert(userIdKey ~= nil, "userId must be a number")
	assert(string.match(userIdKey, "^%d+$"), "userId must be an integer")

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

function PlayerStore:lock(userId: number)
	local userIdKey = assertUserId(userId)
	return self._store:lock(userIdKey)
end

function PlayerStore:unlock(userId: number)
	local userIdKey = assertUserId(userId)
	return self._store:unlock(userIdKey)
end

function PlayerStore:update<T>(userId: number, transformFunction: (data: T) -> T?)
	local userIdKey = assertUserId(userId)
	return self._store:update(userIdKey, transformFunction)
end

function PlayerStore:tx<T>(userIds: { number }, transformFunction: (state: { [number]: T }) -> { [number]: T }?)
	local userIdKeys = Sift.Array.map(userIds, assertUserId)

	local function wrapped(state)
		local userIdState: { [number]: any } = mapKeys(state, tonumber) :: any

		local newUserIdState = transformFunction(userIdState)
		if newUserIdState == nil then
			return nil :: any
		end

		local newState = mapKeys(newUserIdState, assertUserId)
		return newState
	end

	return self._store:tx(userIdKeys, wrapped)
end

function PlayerStore:save(userId: number)
	local userIdKey = assertUserId(userId)
	return self._store:save(userIdKey)
end

return createPlayerStore
