--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local Store = require(script.Parent.Store)
local mapKeys = require(script.Parent.mapKeys)

type PlayerStoreImpl = {
	__index: PlayerStoreImpl,
	get: (self: PlayerStore, userId: number) -> Promise.Promise,
	lock: (self: PlayerStore, userId: number) -> Promise.Promise,
	unlock: (self: PlayerStore, userId: number) -> Promise.Promise,
	update: (self: PlayerStore, userId: number, transformFunction: (data: any) -> any) -> Promise.Promise,
	tx: (
		self: PlayerStore,
		userIds: { number },
		transformFunction: (state: { [number]: any }) -> { [number]: any }?
	) -> Promise.Promise,
	save: (self: PlayerStore, userId: number) -> Promise.Promise,
}

type PlayerStoreProps = {
	_store: Store.Store,
}

type PlayerStore = typeof(setmetatable({} :: PlayerStoreProps, {} :: PlayerStoreImpl))

local function assertUserId(userId: number): string
	local userIdKey = tostring(userId)

	assert(userIdKey ~= nil, "userId must be a number")
	assert(string.match(userIdKey, "^%d+$"), "userId must be an integer")

	return userIdKey
end

local PlayerStore: PlayerStoreImpl = {} :: PlayerStoreImpl
PlayerStore.__index = PlayerStore

local function createPlayerStore(config: Store.StoreConfig): PlayerStore
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

function PlayerStore:update(userId: number, transformFunction: (data: any) -> any)
	local userIdKey = assertUserId(userId)
	return self._store:update(userIdKey, transformFunction)
end

function PlayerStore:tx(userIds: { number }, transformFunction: (state: { [number]: any }) -> { [number]: any }?)
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
