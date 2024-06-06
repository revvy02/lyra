--!strict
--[=[
  @function mapKeys
  @within Dictionary

  @param dictionary {[K]: V} -- The dictionary to map.
  @param keyMapper (key: K) -> X -- The key mapper function.
  @return {[X]: V} -- The mapped dictionary.

  Maps the dictionary keys using the key mapper function.

  ```lua
  local dictionary = { hello = 10, goodbye = 20 }

  local new = mapKeys(dictionary, function(key)
    return key .. "!"
  end) -- { ["hello!"] = 10, ["goodbye!"] = 20 }
  ```
]=]

local function mapKeys<K, V, X>(dictionary: { [K]: V }, keyMapper: (key: K) -> X): { [X]: V }
	local mapped = {}

	for key, value in dictionary do
		local mappedKey = keyMapper(key)
		mapped[mappedKey] = value
	end

	return mapped
end

return mapKeys
