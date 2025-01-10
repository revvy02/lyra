--!strict

--[[
  RFC 6902 implementation in Luau (Roblox) with two public functions:
    1) JSONPatch.applyPatch(doc, patch) -> applies the patch in-place (mutates & returns doc).
    2) JSONPatch.createPatch(original, modified) -> returns a minimal set of patch operations.
]]

--------------------------------------------------------------------------------
--                          JSON Pointer Utilities
--------------------------------------------------------------------------------

local function isArray(tbl: any): boolean
	if type(tbl) ~= "table" then
		return false
	end
	-- Must have integer keys 1..n with no gaps, for # to match
	local n = #tbl
	local count = 0
	for k in tbl do
		if type(k) ~= "number" then
			return false
		end
		count += 1
	end
	return (count == n)
end

local function unescapeSegment(segment: string): string
	-- ~1 -> '/', ~0 -> '~'
	local res = string.gsub(segment, "~1", "/")
	res = string.gsub(res, "~0", "~")
	return res
end

local function escapeSegment(segment: string): string
	-- / -> ~1, ~ -> ~0
	local res = string.gsub(segment, "~", "~0")
	res = string.gsub(res, "/", "~1")
	return res
end

local function parsePointer(pointer: string): { string }
	-- An empty string "" means "root"
	if pointer == "" then
		return {}
	end
	if string.sub(pointer, 1, 1) ~= "/" then
		error("Invalid JSON pointer (must start with / or be empty)")
	end
	local raw = string.sub(pointer, 2) -- skip leading '/'
	local segments = string.split(raw, "/")
	for i, seg in segments do
		segments[i] = unescapeSegment(seg)
	end
	return segments
end

--------------------------------------------------------------------------------
--                          Deep Copy & Deep Equal
--------------------------------------------------------------------------------

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for k, v in value do
		result[k] = deepCopy(v)
	end
	return result
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	-- Compare table sizes
	local countA, countB = 0, 0
	for _ in a do
		countA += 1
	end
	for _ in b do
		countB += 1
	end
	if countA ~= countB then
		return false
	end
	-- Compare all keys
	for k, va in a do
		local vb = b[k]
		if vb == nil then
			return false
		end
		if not deepEqual(va, vb) then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
--                         Core Patch Application
--------------------------------------------------------------------------------

-- We'll define a local helper for array index checking, used by remove/replace/move
local function getArrayIndexOrError(key: string, length: number, context: string): number
	-- `context` is "remove", "replace", or "move" etc., used in error messages
	local idx = tonumber(key)
	if idx == nil then
		error(("'%s' path must be a valid numeric index; got '%s'"):format(context, key))
	end
	idx += 1 -- 0-based to 1-based
	if idx < 1 or idx > length then
		-- match the test's error message style
		error(("Array %s index %d out of bounds for length %d"):format(context, idx - 1, length))
	end
	return idx
end

type PatchOperation = {
	op: string?, -- might be missing or nil, we must check
	path: string?,
	from: string?,
	value: any?,
}

local function applyOperation(doc: any, opObj: PatchOperation): any
	----------------------------------------------------------------------
	-- 1) Validate op
	----------------------------------------------------------------------
	local op = opObj.op
	if type(op) ~= "string" then
		error("Invalid patch operation: 'op' must be a string")
	end

	----------------------------------------------------------------------
	-- 2) Validate path
	----------------------------------------------------------------------
	local path = opObj.path
	if type(path) ~= "string" then
		error("Patch operation missing valid 'path' string")
	end
	local segments = parsePointer(path)

	----------------------------------------------------------------------
	-- 3) Switch on op
	----------------------------------------------------------------------
	if op == "add" then
		local value = opObj.value
		if value == nil then
			error("'add' operation requires 'path' and 'value'")
		end

		-- If path is empty, replace entire doc
		if #segments == 0 then
			return deepCopy(value)
		end

		------------------------------------------------------------------
		-- find the parent object/array
		------------------------------------------------------------------
		local parent = doc
		for i = 1, (#segments - 1) do
			local seg = segments[i]
			if isArray(parent) then
				-- interpret as array index
				seg = getArrayIndexOrError(seg, #parent, op)
			end
			if parent[seg] == nil then
				error(("Parent path segment '%s' does not exist for 'add'"):format(seg))
			end
			if type(parent[seg]) ~= "table" then
				error("Cannot 'add' into non-table parent")
			end
			parent = parent[seg]
		end

		------------------------------------------------------------------
		-- now apply the add to the parent
		------------------------------------------------------------------
		local key = segments[#segments]

		local isAddingIntoEmptyArray = #parent == 0 and key == "-"
		local isAddingIntoPopulatedArray = isArray(parent) and #parent > 0 and (tonumber(key) ~= nil or key == "-")
		if isAddingIntoEmptyArray or isAddingIntoPopulatedArray then
			-- array logic
			if key == "-" then
				-- append
				table.insert(parent, deepCopy(value))
			else
				local index = getArrayIndexOrError(key, #parent, op)
				table.insert(parent, index, deepCopy(value))
			end
		else
			-- object logic
			parent[key] = deepCopy(value)
		end

		return doc
	elseif op == "remove" then
		-- If path is empty, remove entire doc => doc becomes nil
		if #segments == 0 then
			return nil
		end

		------------------------------------------------------------------
		-- find the parent object/array
		------------------------------------------------------------------
		local parent = doc
		for i = 1, (#segments - 1) do
			local seg = segments[i]
			if isArray(parent) then
				seg = getArrayIndexOrError(seg, #parent, op)
			end

			if parent[seg] == nil then
				error(("Cannot remove from non-existent parent path segment '%s'"):format(seg))
			end
			if type(parent[seg]) ~= "table" then
				error("Cannot 'remove' from non-table parent")
			end
			parent = parent[seg]
		end

		------------------------------------------------------------------
		-- now remove from the parent
		------------------------------------------------------------------
		local key = segments[#segments]
		if isArray(parent) and tonumber(key) ~= nil then
			local index = getArrayIndexOrError(key, #parent, op)
			table.remove(parent, index)
		else
			if parent[key] == nil then
				error(("Cannot remove non-existent key '%s'"):format(key))
			end
			parent[key] = nil
		end

		return doc
	elseif op == "replace" then
		local value = opObj.value
		if value == nil then
			error("'replace' operation requires 'value'")
		end

		-- If path is empty, replace entire doc
		if #segments == 0 then
			return deepCopy(value)
		end

		------------------------------------------------------------------
		-- find the parent object/array
		------------------------------------------------------------------
		local parent = doc
		for i = 1, (#segments - 1) do
			local seg = segments[i]
			if isArray(parent) then
				seg = getArrayIndexOrError(seg, #parent, op)
			end

			if parent[seg] == nil then
				error(("Cannot replace within non-existent path segment '%s'"):format(seg))
			end
			if type(parent[seg]) ~= "table" then
				error("Cannot 'replace' on non-table parent")
			end
			parent = parent[seg]
		end

		------------------------------------------------------------------
		-- replace the correct element or property
		------------------------------------------------------------------
		local key = segments[#segments]
		if isArray(parent) and tonumber(key) ~= nil then
			local index = getArrayIndexOrError(key, #parent, op)
			parent[index] = deepCopy(value)
		else
			if parent[key] == nil then
				error(("Cannot replace non-existent path '%s'"):format(key))
			end
			parent[key] = deepCopy(value)
		end

		return doc
	else
		------------------------------------------------------------------
		-- unrecognized operation
		------------------------------------------------------------------
		error(("Unknown or unimplemented operation: %s"):format(op))
	end
end

--------------------------------------------------------------------------------

local JSONPatch = {}

function JSONPatch.applyPatch(doc: any, patch: { PatchOperation }): any
	for _, operation in ipairs(patch) do
		doc = applyOperation(doc, operation)
	end
	return doc
end

--------------------------------------------------------------------------------
--                             createPatch
--------------------------------------------------------------------------------

-- We'll do a minimal diff with LCS for arrays, and a standard object-diff
-- for dictionaries. We'll define local functions first, then unify them in _diffAny.

local function diffObject(
	a: any,
	b: any,
	path: string,
	outOps: { PatchOperation },
	recurse: (any, any, string, { PatchOperation }) -> ()
)
	-- Remove keys in 'a' that are not in 'b'
	for k in a do
		if b[k] == nil then
			table.insert(outOps, {
				op = "remove",
				path = if path == "" then "/" .. tostring(k) else path .. "/" .. tostring(k),
			})
		end
	end

	-- Add or recurse
	for k, v in b do
		if a[k] == nil then
			table.insert(outOps, {
				op = "add",
				path = if path == "" then "/" .. tostring(k) else path .. "/" .. tostring(k),
				value = deepCopy(v),
			})
		else
			local oldVal = a[k]
			if type(oldVal) == "table" and type(v) == "table" then
				-- both objects => recurse
				recurse(oldVal, v, if path == "" then "/" .. tostring(k) else path .. "/" .. tostring(k), outOps)
			else
				if not deepEqual(oldVal, v) then
					table.insert(outOps, {
						op = "replace",
						path = if path == "" then "/" .. tostring(k) else path .. "/" .. tostring(k),
						value = deepCopy(v),
					})
				end
			end
		end
	end
end

-- We'll store partial ops as strings and convert them after building the LCS
local function arrayDiff(
	a: { any },
	b: { any },
	path: string,
	outOps: { PatchOperation },
	recurse: (any, any, string, { PatchOperation }) -> ()
)
	-- We’ll do a standard DP approach: dp[i][j] = best way (min cost)
	-- to transform a[1..i] into b[1..j].  We'll store:
	--   dp[i][j].cost   => minimal number of array edits
	--   dp[i][j].parent => one of "none", "eq", "rem", "add", "rep"
	--   dp[i][j].op     => an op descriptor { kind="remove"/"add"/"replace", i=?, j=? }
	--
	-- We use 1-based indexing for convenience in dp.
	-- a[i] in code is the i-th element (i from 1..#a).
	-- b[j] in code is the j-th element (j from 1..#b).

	local lenA = #a
	local lenB = #b

	-- dp[i][j] is a small record with .cost, .parent, .op, etc.
	local dp: { { { cost: number, op: any, parent: string } } } = {}
	for i = 0, lenA do
		dp[i] = {}
		for j = 0, lenB do
			dp[i][j] = {
				cost = 0,
				parent = "none", -- or "eq", "rem", "add", "rep"
				op = nil,
			}
		end
	end

	-- Initialize base cases:
	-- dp[i][0] => remove i items
	for i = 1, lenA do
		dp[i][0].cost = i
		dp[i][0].parent = "rem"
		dp[i][0].op = { kind = "remove", i = i - 1 }
		-- we also need to know how to "step back":
		-- removing that last item leads us from (i-1,0)
	end
	-- dp[0][j] => add j items
	for j = 1, lenB do
		dp[0][j].cost = j
		dp[0][j].parent = "add"
		dp[0][j].op = { kind = "add", j = j - 1 }
		-- stepping back from (0,j) means (0, j-1)
	end

	-- Fill the DP table
	for i = 1, lenA do
		for j = 1, lenB do
			if deepEqual(a[i], b[j]) then
				-- No cost if they're the same
				dp[i][j].cost = dp[i - 1][j - 1].cost
				dp[i][j].parent = "eq"
				dp[i][j].op = nil -- no op needed
			else
				-- Otherwise, 3 possibilities:
				local removeCost = dp[i - 1][j].cost + 1
				local addCost = dp[i][j - 1].cost + 1
				local repCost = dp[i - 1][j - 1].cost + 1

				local best = repCost
				local bestParent = "rep"
				local bestOp: { i: number?, j: number?, kind: string } = { kind = "replace", i = i - 1, j = j - 1 }

				if removeCost < best then
					best = repCost
					bestParent = "rem"
					bestOp = { kind = "remove", i = i - 1 }
				end
				if addCost < best then
					best = addCost
					bestParent = "add"
					bestOp = { kind = "add", j = j - 1 }
				end

				dp[i][j].cost = best
				dp[i][j].parent = bestParent
				dp[i][j].op = bestOp
			end
		end
	end

	-- Backtrack from (lenA, lenB) to build the raw list of ops (in reverse).
	local revOps = {}
	do
		local i = lenA
		local j = lenB
		while i > 0 or j > 0 do
			local cell = dp[i][j]
			local p = cell.parent
			if p == "none" then
				-- we've reached dp[0][0]
				break
			elseif p == "eq" then
				-- no op => just move diagonal
				i -= 1
				j -= 1
			elseif p == "rem" then
				-- this cell says "remove" => store op & step (i-1,j)
				table.insert(revOps, cell.op)
				i -= 1
			elseif p == "add" then
				table.insert(revOps, cell.op)
				j -= 1
			elseif p == "rep" then
				table.insert(revOps, cell.op)
				i -= 1
				j -= 1
			end
		end
	end

	-- Reverse to get forward ops
	local forwardOps = {}
	for i = #revOps, 1, -1 do
		table.insert(forwardOps, revOps[i])
	end

	-- Now interpret each op in forward order.
	-- We do the same offset-based approach to build actual JSON patch ops.
	local offset = 0
	for _, opInfo in ipairs(forwardOps) do
		if opInfo.kind == "add" then
			local insertIndex = opInfo.j

			-- If we're adding beyond the end, use '-'
			local finalIndexStr = if opInfo.j >= #a + offset then "-" else tostring(insertIndex)

			table.insert(outOps, {
				op = "add",
				path = path .. "/" .. escapeSegment(finalIndexStr),
				value = deepCopy(b[opInfo.j + 1]),
			})
			offset += 1
		elseif opInfo.kind == "remove" then
			-- Remove a[i] at index = offset + opInfo.i
			local removeIndex = offset + opInfo.i
			table.insert(outOps, {
				op = "remove",
				path = path .. "/" .. escapeSegment(tostring(removeIndex)),
			})
			offset -= 1
		elseif opInfo.kind == "replace" then
			-- Replace a[i] with b[j]
			-- We'll see if sub-tables => might do a recursive diff, else direct replace.
			local replaceIndex = offset + opInfo.i
			local subOld = a[opInfo.i + 1]
			local subNew = b[opInfo.j + 1]

			-- same recursion logic as the old code
			if type(subOld) == "table" and type(subNew) == "table" and not isArray(subOld) and not isArray(subNew) then
				-- Recurse into sub-objects
				local subPath = path .. "/" .. escapeSegment(replaceIndex)

				local subOps = {}
				recurse(subOld, subNew, subPath, subOps)
				for _, childOp in ipairs(subOps) do
					table.insert(outOps, childOp)
				end
			else
				-- Direct top-level "replace"
				table.insert(outOps, {
					op = "replace",
					path = path .. "/" .. escapeSegment(tostring(replaceIndex)),
					value = deepCopy(subNew),
				})
			end
		end
	end
end

local function diffAny(a: any, b: any, path: string, outOps: { PatchOperation })
	-- if they're equal, no ops
	if deepEqual(a, b) then
		return
	end

	if isArray(a) and isArray(b) then
		arrayDiff(a, b, path, outOps, diffAny)
	elseif type(a) == "table" and type(b) == "table" and not isArray(a) and not isArray(b) then
		diffObject(a, b, path, outOps, diffAny)
	else
		-- just replace
		table.insert(outOps, {
			op = "replace",
			path = path,
			value = deepCopy(b),
		})
	end
end

function JSONPatch.createPatch(original: any, modified: any): { PatchOperation }
	local ops = {}
	diffAny(original, modified, "", ops)
	return ops
end

return JSONPatch
