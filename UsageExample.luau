local Mix = {} :: any
local t = {} :: any

local store = Mix.createPlayerStore({
	name = `test`,
	template = {},
	schema = t.strictInterface({
		coins = t.number(),
	}),
	migrations = Mix.migrationsFromFolder({ -- imagine you pass in a real folder instance with ModuleScripts here
		[2] = function(data)
			data.newStuff = true
			return data
		end,
	}),
})

store:lock(123):expect()
local _data = store:get(123):expect()
store
	:update(123, function(data)
		data.foo = "bar"
		return data
	end)
	:expect()
store:unlock(123):expect()
print(store:lock(123):expect())

store:tx({ 1234, 4567 }, function(state)
	state[1234].items = {}
	return state
end)
