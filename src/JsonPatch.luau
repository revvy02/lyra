--!strict

--[[
  RFC 6902 implementation in Luau (Roblox) with two public functions:
    1) JSONPatch.applyPatch(doc, patch) -> applies the patch in-place (mutates & returns doc).
    2) JSONPatch.createPatch(original, modified) -> returns a minimal set of patch operations.
]]

--------------------------------------------------------------------------------
--                          JSON Pointer Utilities
--------------------------------------------------------------------------------

local function unescapeSegment(segment: string): string
	-- ~1 -> '/', ~0 -> '~'
	local res = string.gsub(segment, "~1", "/")
	res = string.gsub(res, "~0", "~")
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
	if idx < 0 or idx >= length then
		-- match the test's error message style
		error(("Array %s index %d out of bounds for length %d"):format(context, idx, length))
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
	-- The tests expect "Invalid patch operation: 'op' must be a string"
	-- if op is missing or not a string.
	if typeof(op) ~= "string" then
		error("Invalid patch operation: 'op' must be a string")
	end

	----------------------------------------------------------------------
	-- 2) Validate path
	----------------------------------------------------------------------
	local path = opObj.path
	if typeof(path) ~= "string" then
		error("Patch operation missing valid 'path' string")
	end
	local segments = parsePointer(path)

	----------------------------------------------------------------------
	-- 3) Switch
	----------------------------------------------------------------------
	if op == "add" then
		-- The tests expect an error message: "'add' operation requires 'path' and 'value'"
		-- if 'value' is nil.
		local value = opObj.value
		if value == nil then
			error("'add' operation requires 'path' and 'value'")
		end

		if #segments == 0 then
			-- replace entire doc
			return deepCopy(value)
		end

		-- find parent and key
		local parent = doc
		for i = 1, (#segments - 1) do
			local seg = segments[i]
			if type(parent) ~= "table" then
				error("Cannot 'add' into non-table parent")
			end
			if parent[seg] == nil then
				-- For 'add', parent must exist, but the final key can be new.
				error(("Parent path segment '%s' does not exist for 'add'"):format(seg))
			end
			parent = parent[seg]
		end
		local key = segments[#segments]

		if type(parent) ~= "table" then
			error("Cannot 'add' into non-table parent")
		end

		-- handle array vs object
		-- if key == "-" => append
		local maybeIndex = tonumber(key)
		if key == "-" and #parent >= 0 and type(parent) == "table" then
			-- append
			table.insert(parent, deepCopy(value))
		elseif maybeIndex ~= nil and type(parent) == "table" then
			local length = #parent
			if maybeIndex < 0 or maybeIndex > length then
				error(("Array add index %d out of bounds for length %d"):format(maybeIndex, length))
			end
			table.insert(parent, maybeIndex + 1, deepCopy(value))
		else
			-- treat as object key
			parent[key] = deepCopy(value)
		end
		return doc
	elseif op == "remove" then
		if #segments == 0 then
			-- removing entire doc
			return nil
		end

		-- find parent
		local parent = doc
		for i = 1, (#segments - 1) do
			local seg = segments[i]
			if type(parent) ~= "table" then
				error("Cannot 'remove' from non-table parent")
			end
			if parent[seg] == nil then
				error(("Cannot remove from non-existent parent path segment '%s'"):format(seg))
			end
			parent = parent[seg]
		end
		local key = segments[#segments]

		if type(parent) ~= "table" then
			error("Cannot 'remove' from non-table parent")
		end

		local maybeIndex = tonumber(key)
		if maybeIndex ~= nil and #parent >= 0 then
			local length = #parent
			if maybeIndex < 0 or maybeIndex >= length then
				error(("Array remove index %d out of bounds for length %d"):format(maybeIndex, length))
			end
			table.remove(parent, maybeIndex + 1)
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

		if #segments == 0 then
			-- replace entire doc
			return deepCopy(value)
		end

		-- find parent
		local parent = doc
		for i = 1, (#segments - 1) do
			local seg = segments[i]
			if type(parent) ~= "table" then
				error("Cannot 'replace' on non-table parent")
			end
			if parent[seg] == nil then
				error(("Cannot replace within non-existent path segment '%s'"):format(seg))
			end
			parent = parent[seg]
		end
		local key = segments[#segments]

		if type(parent) ~= "table" then
			error("Cannot 'replace' on non-table parent")
		end

		local maybeIndex = tonumber(key)
		if maybeIndex ~= nil and #parent >= 0 then
			-- array
			local length = #parent
			if maybeIndex < 0 or maybeIndex >= length then
				error(("Cannot replace non-existent path '%s'"):format(key))
			end
			parent[maybeIndex + 1] = deepCopy(value)
		else
			if parent[key] == nil then
				error(("Cannot replace non-existent path '%s'"):format(key))
			end
			parent[key] = deepCopy(value)
		end
		return doc
	elseif op == "move" then
		local from = opObj.from
		if type(from) ~= "string" then
			error("'move' operation requires a 'from' field")
		end

		-- if from == path, do nothing
		if from == path then
			return doc
		end

		-- 1) read from
		local fromSegments = parsePointer(from)
		if #fromSegments == 0 then
			-- moving entire doc => doc becomes nil, then we add it at path
			local oldDoc = doc
			doc = nil
			doc = applyOperation(doc, { op = "add", path = path, value = oldDoc })
			return doc
		end

		-- find fromParent
		local fromParent = doc
		for i = 1, (#fromSegments - 1) do
			local seg = fromSegments[i]
			if type(fromParent) ~= "table" then
				error("Cannot 'move' from non-table parent")
			end
			if fromParent[seg] == nil then
				error(("Cannot move from non-existent path segment '%s'"):format(seg))
			end
			fromParent = fromParent[seg]
		end
		local fromKey = fromSegments[#fromSegments]
		if type(fromParent) ~= "table" then
			error("Cannot 'move' from non-table parent")
		end

		local val
		local fromIdx = tonumber(fromKey)
		if fromIdx ~= nil and #fromParent >= 0 then
			-- array case
			local length = #fromParent
			if fromIdx < 0 or fromIdx >= length then
				error(("Array move index %d out of bounds for length %d"):format(fromIdx, length))
			end
			val = fromParent[fromIdx + 1]
		else
			if fromParent[fromKey] == nil then
				error(("Cannot move from non-existent path '%s'"):format(fromKey))
			end
			val = fromParent[fromKey]
		end

		-- 2) remove it from old location
		doc = applyOperation(doc, { op = "remove", path = from })

		-- 3) add it to new location
		doc = applyOperation(doc, { op = "add", path = path, value = val })
		return doc
	elseif op == "copy" then
		local from = opObj.from
		if type(from) ~= "string" then
			error("'copy' operation requires a 'from' field")
		end

		-- if from == path, do nothing
		if from == path then
			return doc
		end

		local fromSegments = parsePointer(from)
		if #fromSegments == 0 then
			-- copy entire doc
			local cloned = deepCopy(doc)
			doc = applyOperation(doc, { op = "add", path = path, value = cloned })
			return doc
		end

		-- find fromParent
		local fromParent = doc
		for i = 1, (#fromSegments - 1) do
			local seg = fromSegments[i]
			if type(fromParent) ~= "table" then
				error("Cannot 'copy' from non-table parent")
			end
			if fromParent[seg] == nil then
				error(("Cannot copy from non-existent path segment '%s'"):format(seg))
			end
			fromParent = fromParent[seg]
		end
		local fromKey = fromSegments[#fromSegments]
		if type(fromParent) ~= "table" then
			error("Cannot 'copy' from non-table parent")
		end

		local val
		local fromIdx = tonumber(fromKey)
		if fromIdx ~= nil and #fromParent >= 0 then
			local length = #fromParent
			if fromIdx < 0 or fromIdx >= length then
				error(("Array copy index %d out of bounds for length %d"):format(fromIdx, length))
			end
			val = fromParent[fromIdx + 1]
		else
			if fromParent[fromKey] == nil then
				error(("Cannot copy from non-existent path '%s'"):format(fromKey))
			end
			val = fromParent[fromKey]
		end

		local cloned = deepCopy(val)
		doc = applyOperation(doc, { op = "add", path = path, value = cloned })
		return doc
	else
		-- The tests expect: "Unknown or unimplemented operation: morph"
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

local function isJsonArray(tbl: any): boolean
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
	local memo = {}

	local function dist(i: number, j: number)
		local key = tostring(i) .. "," .. tostring(j)
		if memo[key] then
			return memo[key]
		end
		if i == 0 and j == 0 then
			memo[key] = { ops = {}, cost = 0 }
			return memo[key]
		end
		if i == 0 then
			-- must add b[j]
			local prev = dist(i, j - 1)
			local c = {
				ops = { table.unpack(prev.ops) },
				cost = prev.cost + 1,
			}
			table.insert(c.ops, ("ADD:%d"):format(j - 1))
			memo[key] = c
			return c
		elseif j == 0 then
			-- must remove a[i]
			local prev = dist(i - 1, j)
			local c = {
				ops = { table.unpack(prev.ops) },
				cost = prev.cost + 1,
			}
			table.insert(c.ops, ("REM:%d"):format(i - 1))
			memo[key] = c
			return c
		else
			-- check equality
			if deepEqual(a[i], b[j]) then
				local diag = dist(i - 1, j - 1)
				memo[key] = { ops = { table.unpack(diag.ops) }, cost = diag.cost }
				return memo[key]
			end
			-- remove => i-1, j
			local removeBase = dist(i - 1, j)
			local removeCandidate = {
				ops = { table.unpack(removeBase.ops) },
				cost = removeBase.cost + 1,
				action = ("REM:%d"):format(i - 1),
			}

			-- add => i, j-1
			local addBase = dist(i, j - 1)
			local addCandidate = {
				ops = { table.unpack(addBase.ops) },
				cost = addBase.cost + 1,
				action = ("ADD:%d"):format(j - 1),
			}

			-- replace => i-1, j-1
			local repBase = dist(i - 1, j - 1)
			local repCandidate = {
				ops = { table.unpack(repBase.ops) },
				cost = repBase.cost + 1,
				action = ("REP:%d,%d"):format(i - 1, j - 1),
			}

			local best
			if repCandidate.cost < removeCandidate.cost and repCandidate.cost < addCandidate.cost then
				best = repCandidate
			elseif removeCandidate.cost < addCandidate.cost then
				best = removeCandidate
			else
				best = addCandidate
			end
			table.insert(best.ops, best.action)
			memo[key] = { ops = best.ops, cost = best.cost }
			return memo[key]
		end
	end

	local final = dist(#a, #b)
	-- interpret final.ops
	local offset = 0
	for _, code in ipairs(final.ops) do
		local prefix = string.sub(code, 1, 3) -- "ADD","REM","REP"
		if prefix == "ADD" then
			local idx = tonumber(string.match(code, "^ADD:(%d+)"))
			if idx == nil then
				continue
			end
			local insertIndex = offset + idx + 1
			local finalIndexStr = if insertIndex >= (#a + offset) then "-" else tostring(insertIndex)
			table.insert(outOps, {
				op = "add",
				path = if path == "" then "/" .. finalIndexStr else path .. "/" .. finalIndexStr,
				value = deepCopy(b[idx + 1]),
			})
			offset += 1
		elseif prefix == "REM" then
			local idx = tonumber(string.match(code, "^REM:(%d+)"))
			if idx == nil then
				continue
			end
			local removeIndex = idx + offset
			table.insert(outOps, {
				op = "remove",
				path = if path == "" then "/" .. tostring(removeIndex) else path .. "/" .. tostring(removeIndex),
			})
			offset -= 1
		else
			-- "REP"
			local iStr, jStr = string.match(code, "^REP:(%d+),(%d+)")
			if iStr and jStr then
				local iNum = tonumber(iStr)
				local jNum = tonumber(jStr)
				if iNum ~= nil and jNum ~= nil then
					local replaceIndex = iNum + offset
					-- Instead of a raw "replace" ignoring sub-structure, let's do a recursion:
					-- Because maybe they're both tables => we can produce smaller diffs inside.
					local subOld = a[iNum + 1]
					local subNew = b[jNum + 1]
					if
						type(subOld) == "table"
						and type(subNew) == "table"
						and not isJsonArray(subOld)
						and not isJsonArray(subNew)
					then
						-- We recurse
						local subPath = if path == "" then "/" .. replaceIndex else path .. "/" .. replaceIndex
						-- do a local list for subOps
						local subOps = {}
						recurse(subOld, subNew, subPath, subOps)
						for _, o in ipairs(subOps) do
							table.insert(outOps, o)
						end
					else
						-- direct replace
						table.insert(outOps, {
							op = "replace",
							path = if path == ""
								then "/" .. tostring(replaceIndex)
								else path .. "/" .. tostring(replaceIndex),
							value = deepCopy(subNew),
						})
					end
				end
			end
		end
	end
end

local function diffAny(a: any, b: any, path: string, outOps: { PatchOperation })
	-- if they're equal, no ops
	if deepEqual(a, b) then
		return
	end

	if isJsonArray(a) and isJsonArray(b) then
		arrayDiff(a, b, path, outOps, diffAny)
	elseif type(a) == "table" and type(b) == "table" and not isJsonArray(a) and not isJsonArray(b) then
		diffObject(a, b, path, outOps, diffAny)
	else
		-- just replace
		table.insert(outOps, {
			op = "replace",
			path = if path == "" then "" else path,
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
