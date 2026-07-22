local JsonPretty = {}

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(s: string): string
	local escaped = (s :: string):gsub('[%c"\\]', function(c: string)
		return ESCAPES[c] or string.format("\\u%04x", c:byte())
	end)
	return `"{escaped}"`
end

local function encodeNumber(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "0" -- NaN/Inf can't round-trip through JSON; shouldn't occur for GUI properties
	end
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return tostring(n)
end

-- True for empty tables and 1..n sequences with no gaps or non-integer keys.
local function isArray(t: { [any]: any }): boolean
	local count = 0
	for _ in t do
		count += 1
	end
	if count == 0 then
		return true
	end
	for i = 1, count do
		if t[i] == nil then
			return false
		end
	end
	return true
end

local function encodeValue(value: any, indent: string): string
	local t = typeof(value)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return tostring(value)
	elseif t == "number" then
		return encodeNumber(value)
	elseif t == "string" then
		return encodeString(value)
	elseif t == "table" then
		local nextIndent = indent .. "\t"
		if isArray(value) then
			local count = 0
			for _ in value do
				count += 1
			end
			if count == 0 then
				return "[]"
			end
			local parts = {}
			for i = 1, count do
				table.insert(parts, nextIndent .. encodeValue(value[i], nextIndent))
			end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
		else
			local keys = {}
			for k in value do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			if #keys == 0 then
				return "{}"
			end
			local parts = {}
			for _, k in keys do
				table.insert(parts, `{nextIndent}{encodeString(tostring(k))}: {encodeValue(value[k], nextIndent)}`)
			end
			return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
		end
	end
	return "null"
end

function JsonPretty.encode(value: any): string
	return encodeValue(value, "")
end

return JsonPretty
