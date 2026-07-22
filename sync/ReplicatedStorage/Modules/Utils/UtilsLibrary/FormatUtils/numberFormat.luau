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
	decimals = decimals or 1

	local magnitude = math.floor(math.log(math.max(1, math.abs(num)), 1000))
	local suffix = SUFFIXES[magnitude + 1] or ("e+" .. magnitude)
	local scaled = math.floor(num * (10 ^ decimals / (1000 ^ magnitude))) / (10 ^ decimals)
	local formatted = string.format("%." .. decimals .. "f", scaled):gsub("%.?0+$", "")

	return formatted .. suffix
end

function NumberFormatter.Commas(num: number)
	local str = tostring(num)

	while str:match("^(-?%d+)(%d%d%d)") do
		str = str:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
	end

	return str
end

return NumberFormatter
