local function getBackoffTime(totalTime: number, totalDelays: number, index: number): number
	local sumOfSeries = 0
	for n = 1, totalDelays do
		sumOfSeries += math.sqrt(n)
	end
	local baseInterval = totalTime / sumOfSeries
	return baseInterval * math.sqrt(index)
end

return getBackoffTime
