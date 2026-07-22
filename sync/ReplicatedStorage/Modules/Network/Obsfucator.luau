--|| Services
local Workspace = game:GetService("Workspace")

--|| Constants
local KEY_ROTATION_INTERVAL = 30 -- Cycles the cypher every 30 seconds
local PRECISION = 100000         -- Retains 5 decimal points of precision
local DELIMITER = "/u/0//-/"

local BASE_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local BASE = #BASE_CHARS

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Private Functions ]] --

function Local.GetCypherShift(seed: number): number
	local hash = (seed * 1664525 + 1013904223) % (2 ^ 32)
	return math.floor(hash % BASE)
end

function Local.IntToBase62(n: number, shift: number): string
	if n == 0 then
		local charIdx = (1 + shift) % BASE
		if charIdx == 0 then charIdx = BASE end
		return string.sub(BASE_CHARS, charIdx, charIdx)
	end

	local parts = {}
	while n > 0 do
		local remainder = n % BASE
		local shiftedIdx = ((remainder + shift) % BASE) + 1
		table.insert(parts, 1, string.sub(BASE_CHARS, shiftedIdx, shiftedIdx))
		n = math.floor(n / BASE)
	end
	return table.concat(parts, "")
end

function Local.Base62ToInt(str: string, shift: number): number?
	local result = 0
	for i = 1, #str do
		local char = string.sub(str, i, i)
		local rawIdx = string.find(BASE_CHARS, char, 1, true)
		if not rawIdx then return nil end
		local unshiftedRemainder = (rawIdx - 1 - shift) % BASE
		result = result * BASE + unshiftedRemainder
	end
	return result
end

function Local.EncodeNumber(n: number, shift: number): string
	local negative = n < 0
	local absInt = math.round(math.abs(n) * PRECISION)
	local encoded = Local.IntToBase62(absInt, shift)
	return (negative and "N" or "P") .. encoded
end

function Local.DecodeNumber(s: string, shift: number): number?
	if #s < 2 then return nil end
	local sign = string.sub(s, 1, 1)
	local body = string.sub(s, 2)
	if sign ~= "N" and sign ~= "P" then return nil end
	local absInt = Local.Base62ToInt(body, shift)
	if not absInt then return nil end
	local value = absInt / PRECISION
	return sign == "N" and -value or value
end

-- [[ Public Functions ]] --

function Shared.Encode(values: { number }): string
	local seed = math.floor(Workspace:GetServerTimeNow() / KEY_ROTATION_INTERVAL)
	local shift = Local.GetCypherShift(seed)

	local parts = {}
	for _, v in values do
		table.insert(parts, Local.EncodeNumber(v, shift))
	end

	return table.concat(parts, DELIMITER)
end

function Shared.Decode(payload: string): { number }?
	if type(payload) ~= "string" or #payload == 0 then return nil end

	local currentSeed = math.floor(Workspace:GetServerTimeNow() / KEY_ROTATION_INTERVAL)
	local seedsToTry = { currentSeed, currentSeed - 1 }

	for _, seed in seedsToTry do
		local shift = Local.GetCypherShift(seed)
		local parts = string.split(payload, DELIMITER)
		local results = {}
		local success = true

		for _, part in parts do
			local val = Local.DecodeNumber(part, shift)
			if not val then
				success = false
				break
			end
			table.insert(results, val)
		end

		if success then
			return results
		end
	end

	return nil
end

return Shared