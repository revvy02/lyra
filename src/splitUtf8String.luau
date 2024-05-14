--!strict

local function splitUtf8String(str: string, maxSizeBytes: number): { string }
	if str == "" then
		return {}
	end

	if maxSizeBytes <= 0 then
		error("maxSizeBytes must be greater than 0")
	end

	local sections = {}
	local prevOffset = 1

	while true do
		-- Get the index of the last codepoint that *starts* within bounds.
		local index = utf8.len(str, prevOffset, math.min(#str, prevOffset + maxSizeBytes))
		assert(index ~= nil, "invalid utf8 string")

		-- We don't know if the width of the codepoint at `index` extends beyond
		-- bounds, so we calculate the width by subtracting 1 from the *next*
		-- codepoint.
		local nextCodepointOffset = utf8.offset(str, index + 1, prevOffset)
		assert(nextCodepointOffset ~= nil, "invalid utf8 string")
		if nextCodepointOffset - (prevOffset - 1) - 1 > maxSizeBytes then
			-- The codepoint at `index` is too wide to fit within bounds, so we
			-- shrink by one codepoint.
			index -= 1
		end

		local offset = utf8.offset(str, index + 1, prevOffset)
		assert(offset ~= nil, "invalid utf8 string")
		offset -= 1

		table.insert(sections, string.sub(str, prevOffset, offset))
		prevOffset = offset + 1
		if prevOffset > #str then
			break
		end
	end

	return sections
end

return splitUtf8String
