local ReplicatedStorage = game:GetService("ReplicatedStorage")

local gt = require(ReplicatedStorage.Packages.GreenTea)
local Promise = require(ReplicatedStorage.Packages.Promise)

local stringTypeRaw = gt.string()
local anyTypeRaw = gt.any({ allowNil = true })
local userIdsTypeRaw = gt.array(gt.number())
local metadataTypeRaw = gt.dictionary(gt.string(), anyTypeRaw)

local promiseTypeRaw = gt.withCustom((nil :: any) :: Promise.Promise, Promise.is, "Promise")

local toTypedPromise: <Out...>(Out...) -> Promise.TypedPromise<Out...> = function(...)
	return ...
end

local function checkDataStoreKeyInfo(keyInfo: any): (boolean, string?)
	if typeof(keyInfo) ~= "table" and (typeof(keyInfo) ~= "Instance" or not keyInfo:IsA("DataStoreKeyInfo")) then
		return false, "expected a DataStoreKeyInfo instance"
	end

	if typeof(keyInfo) == "table" then
		if keyInfo._metadata == nil or keyInfo._userIds == nil then
			return false, "expected a DataStoreKeyInfo instance"
		end
	end

	return true
end

local dataStoreKeyInfoTypeRaw =
	gt.withCustom((nil :: any) :: DataStoreKeyInfo, checkDataStoreKeyInfo, "DataStoreKeyInfo")

local selfTypeRaw = gt.any({ allowNil = true })

local getFnTypeRaw = gt.fn(
	gt.args(selfTypeRaw, stringTypeRaw, stringTypeRaw),
	gt.returns(toTypedPromise(gt.tuple(anyTypeRaw, gt.optional(dataStoreKeyInfoTypeRaw))))
)

local setFnTypeRaw = gt.fn(
	gt.args(
		selfTypeRaw,
		stringTypeRaw,
		stringTypeRaw,
		anyTypeRaw,
		gt.optional(userIdsTypeRaw),
		gt.optional(metadataTypeRaw)
	),
	gt.returns(toTypedPromise(stringTypeRaw))
)

local transformFunctionTypeRaw = gt.fn(
	gt.args(selfTypeRaw, anyTypeRaw, dataStoreKeyInfoTypeRaw),
	gt.returns(gt.tuple(anyTypeRaw, gt.optional(userIdsTypeRaw), gt.optional(gt.table({ [gt.string()] = anyTypeRaw }))))
)

local updateFnTypeRaw = gt.fn(
	gt.args(selfTypeRaw, stringTypeRaw, stringTypeRaw, transformFunctionTypeRaw),
	gt.returns(toTypedPromise(gt.tuple(anyTypeRaw, dataStoreKeyInfoTypeRaw)))
)

local removeFnTypeRaw = gt.fn(
	gt.args(selfTypeRaw, stringTypeRaw, stringTypeRaw),
	gt.returns(toTypedPromise(gt.tuple(gt.optional(anyTypeRaw), gt.optional(dataStoreKeyInfoTypeRaw))))
)

local function wrapPromiseFn<T>(fnType: T, fn: any): T
	local fnGtType = gt.typecast(fnType)
	assert(fnGtType.fn ~= nil, "fnType must be a GreenTea function type. Use gt.fn to create a function type")

	return function(...: any)
		fnGtType.fn.args:assert(...)

		local resultPromise = (fn :: any)(...)
		promiseTypeRaw:assert(resultPromise)

		return resultPromise:andThen(function(...)
			fnGtType.fn.returns:assert(...)
			return ...
		end)
	end :: any
end

return {
	wrapPromiseFn = wrapPromiseFn,
	getFnType = getFnTypeRaw,
	setFnType = setFnTypeRaw,
	updateFnType = updateFnTypeRaw,
	removeFnType = removeFnTypeRaw,
}
