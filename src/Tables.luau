--!strict

local function copyDeep<T>(t: T): T
	local new = table.clone(t :: any)

	for key, value in t :: any do
		if type(value) == "table" then
			new[key] = copyDeep(value)
		end
	end

	return new :: any
end

local function mergeDeep<T>(...: any): T
	local result = {}

	for tIndex = 1, select("#", ...) do
		local t = select(tIndex, ...)

		if type(t) ~= "table" then
			continue
		end

		for key, value in t do
			if type(value) == "table" then
				if result[key] == nil or type(result[key]) ~= "table" then
					result[key] = copyDeep(value)
				else
					result[key] = mergeDeep(result[key], value)
				end
			else
				result[key] = value
			end
		end
	end

	return result :: any
end

local function map<T, U>(array: { T }, mapper: (value: T, index: number, array: { T }) -> U?): { U }
	local mapped = {}

	for index, value in array do
		local mappedValue = mapper(value, index, array)

		if mappedValue ~= nil then
			table.insert(mapped, mappedValue)
		end
	end

	return mapped
end

local function equalsDeep(a: { [any]: any }, b: { [any]: any }): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end

	for key, value in a do
		if not equalsDeep(value, b[key]) then
			return false
		end
	end

	for key, value in b do
		if not equalsDeep(value, a[key]) then
			return false
		end
	end

	return true
end

local function freezeDeep<T>(t: T): T
	local result = {}

	for key, value in t :: any do
		if type(value) == "table" then
			result[key] = freezeDeep(value)
		else
			result[key] = value
		end
	end

	table.freeze(result)

	return result :: any
end

type RemovalNode = {
	keys: { any }?,
	children: { [any]: RemovalNode }?,
}

type DiffResult = {
	changes: { [any]: any },
	removals: RemovalNode?,
}

local function diffRecursive(old: { [any]: any }, new: { [any]: any }): (any, RemovalNode?)
	local changes = {}
	local removals: RemovalNode

	for key, newValue in new do
		local oldValue = old[key]

		if oldValue == nil then
			changes[key] = copyDeep(newValue)
		elseif typeof(newValue) == "table" and typeof(oldValue) == "table" then
			local nestedChanges, nestedRemovals = diffRecursive(oldValue, newValue)

			if next(nestedChanges) then
				changes[key] = nestedChanges
			end

			if nestedRemovals then
				removals = removals or { children = {} }
				removals.children = removals.children or {};
				(removals :: any).children[key] = nestedRemovals
			end
		elseif oldValue ~= newValue then
			changes[key] = newValue
		end
	end

	for key in old do
		if new[key] == nil then
			removals = removals or { keys = {} }
			removals.keys = removals.keys or {}
			table.insert((removals :: any).keys, key)
		end
	end

	return changes, removals
end

local function getDiff(oldTable: { [any]: any }, newTable: { [any]: any }): DiffResult
	local changes, removals = diffRecursive(oldTable, newTable)
	return { changes = changes, removals = removals }
end

local function applyRemovals(tbl: { [any]: any }, removals: RemovalNode)
	if removals.keys then
		for _, key in removals.keys do
			tbl[key] = nil
		end
	end

	if removals.children then
		for key, nestedRemovals in removals.children do
			if tbl[key] then
				applyRemovals(tbl[key], nestedRemovals)
			end
		end
	end
end
local function applyDiff(baseTable: { [any]: any }, diff: DiffResult): { [any]: any }
	local result = copyDeep(baseTable)

	if diff.removals then
		applyRemovals(result, diff.removals)
	end

	return mergeDeep(result, diff.changes)
end

return {
	copyDeep = copyDeep,
	mergeDeep = mergeDeep,
	equalsDeep = equalsDeep,
	freezeDeep = freezeDeep,
	map = map,
	getDiff = getDiff,
	applyDiff = applyDiff,
}
