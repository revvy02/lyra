--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local t = require(ReplicatedStorage.Packages.t)

local metadataCheck = t.map(t.string, t.any)
local userIdsCheck = t.array(t.number)

local function callableCheck(value: any): (boolean, string?)
	if t.callback(value) then
		return true
	end

	local ok = t.table(value)
	if not ok then
		return false, `expected a mock object, got {typeof(value)}`
	end

	local mt = getmetatable(value)
	if mt == nil then
		return false, `expected a mock object, got uncallable table`
	end

	if mt.__call == nil then
		return false, `expected a mock object, got uncallable table`
	end

	return true
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

local function getNow()
	return DateTime.now().UnixTimestampMillis / 1000
end

return {
	metadataCheck = metadataCheck,
	userIdsCheck = userIdsCheck,
	callableCheck = callableCheck,
	checkDataStoreKeyInfo = checkDataStoreKeyInfo,
	getNow = getNow,
}
