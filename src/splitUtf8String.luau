local function splitUtf8String(str: string, maxSizeBytes: number): { string }
	local sections = {}
	local prevOffset = 1

	while true do
		-- Get the index of the last codepoint that *starts* within bounds.
		local index = utf8.len(str, prevOffset, math.min(#str, prevOffset + maxSizeBytes))

		-- We don't know if the width of the codepoint at `index` extends beyond
		-- bounds, so we calculate the width by subtracting 1 from the *next*
		-- codepoint.
		local nextCodepointOffset = utf8.offset(str, index + 1, prevOffset)
		if nextCodepointOffset - (prevOffset - 1) - 1 > maxSizeBytes then
			-- The codepoint at `index` is too wide to fit within bounds, so we
			-- shrink by one codepoint.
			index -= 1
		end

		local offset = utf8.offset(str, index + 1, prevOffset)
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
