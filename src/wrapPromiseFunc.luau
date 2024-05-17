--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)

local function wrapPromiseFunc<T>(
	func: T,
	argsCheck: (...any) -> (boolean, string?),
	returnsCheck: (...any) -> (boolean, string?)
): T
	return function(...)
		local traceback = debug.traceback()
		local argsOk, argsErr = argsCheck(...)
		assert(argsOk, `wrapPromiseFunc expected args to pass check, got: {argsErr}: {...}\ntrace: {traceback}`)

		local p = (func :: any)(...)
		assert(Promise.is(p), `wrapPromiseFunc expected a Promise, got {typeof(p)}: {...}\ntrace: {traceback}`)

		return p:andThen(function(...)
			local returnsOk, returnsErr = returnsCheck(...)
			if returnsErr then
				print(...)
			end
			assert(
				returnsOk,
				`wrapPromiseFunc expected returns to pass check, got: {returnsErr}: {...}\ntrace: {traceback}`
			)
			return ...
		end)
	end :: any
end

return wrapPromiseFunc
