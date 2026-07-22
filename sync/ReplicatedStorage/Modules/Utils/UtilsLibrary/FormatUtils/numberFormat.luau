local NumberFormatter = {}

local SUFFIXES = {
	"", 
	"K", 
	"M", 
	"B", 
	"T", 
	"Qa", 
	"Qi", 
	"Sx", 
	"Sp", 
	"Oc", 
	"No", 
	"Dc", 
	"Ud", 
	"Dd", 
	"Td", 
	"Qad", 
	"Qid", 
	"Sxd", 
	"Spd", 
	"Ocd", 
	"Nod", 
	"Vg", 
	"Uvg", 
	"Dvg", 
	"Tvg"
}

function NumberFormatter.Round(num: number, decimals: number?): number
	local multiplier = 10 ^ (decimals or 1)
	return math.floor(num * multiplier + 0.5) / multiplier
end

function NumberFormatter.Abbreviate(num: number, decimals: number?): string
	decimals = decimals or 1 -- default to 1 decimal place

	-- find magnitude (thousands, millions, etc.)
	local magnitude = math.floor(math.log(math.max(1, math.abs(num)), 1000))

	-- pick suffix, or fallback to scientific notation
	local suffix = SUFFIXES[magnitude + 1] or ("e+" .. magnitude)

	-- scale the number down (e.g., 1,200 -> 1.2)
	local scaled = math.floor(num * (10 ^ decimals / (1000 ^ magnitude))) / (10 ^ decimals)

	-- format with the correct number of decimals, strip trailing zeros
	local formatted = string.format("%." .. decimals .. "f", scaled):gsub("%.?0+$", "")

	return formatted .. suffix
end

function NumberFormatter.Commas(num: number)
	-- convert to string so we can manipulate with patterns
	local str = tostring(num)

	-- repeatedly insert commas every 3 digits
	while str:match("^(-?%d+)(%d%d%d)") do
		str = str:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
	end

	return str
end

return NumberFormatter
