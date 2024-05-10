--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)

local function wrapPromiseFunc<T>(
	func: T,
	argsCheck: (...any) -> (boolean, string?),
	returnsCheck: (...any) -> (boolean, string?)
): T
	return function(...)
		assert(argsCheck(...))

		local p = (func :: any)(...)
		assert(Promise.is(p), "expected a Promise")

		return p:andThen(function(...)
			assert(returnsCheck(...))
			return ...
		end)
	end :: any
end

return wrapPromiseFunc
