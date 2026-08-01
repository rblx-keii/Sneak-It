-- Time formatting utilities
local TimeFormatter = {}

-- Converts seconds into "Xd Yh Zm" style, only showing needed parts
function TimeFormatter.FormatDHMS(seconds)
	seconds = math.round(seconds)
	local days = math.floor(seconds / 86400)
	seconds = seconds % 86400
	local hours = math.floor(seconds / 3600)
	seconds = seconds % 3600
	local minutes = math.floor(seconds / 60)
	seconds = seconds % 60

	local result = ""
	if days >= 1 then
		result = result .. string.format("%dd ", days)
	end
	if days >= 1 or hours >= 1 then
		result = result .. string.format("%dh ", hours)
	end
	if hours >= 1 or minutes >= 1 then
		result = result .. string.format("%dm ", minutes)
	end
	if hours <= 0 and minutes <= 0 and days <= 0 then
		result = result .. string.format("%ds", seconds)
	end
	return result
end

-- Converts seconds into "D:HH:MM:SS" style (digital clock)
function TimeFormatter.FormatDigital(seconds)
	seconds = math.round(seconds)
	local days = math.floor(seconds / 86400)
	seconds = seconds % 86400
	local hours = math.floor(seconds / 3600)
	seconds = seconds % 3600
	local minutes = math.floor(seconds / 60)
	seconds = seconds % 60

	local result = ""
	if days >= 1 then
		result = result .. string.format("%d:", days)
	end
	if days >= 1 or hours >= 1 then
		result = result .. string.format("%02d:", hours)
	end
	if hours >= 1 or minutes >= 1 or days >= 1 then
		result = result .. string.format("%02d:", minutes)
	end
	result = result .. string.format("%02d", seconds)
	return result
end

-- Converts seconds into just "Xs" (plain seconds)
function TimeFormatter.FormatSeconds(seconds)
	seconds = math.max(0, math.floor(math.round(seconds)))
	return string.format("%ds", seconds)
end

-- Flexible short format (e.g., "1d 2h 3m", "2h 30m 10s", etc.)
function TimeFormatter.FormatCompact(seconds)
	seconds = math.max(0, math.floor(math.round(seconds)))
	local days = math.floor(seconds / 86400)
	seconds = seconds % 86400
	local hours = math.floor(seconds / 3600)
	seconds = seconds % 3600
	local minutes = math.floor(seconds / 60)
	seconds = seconds % 60

	if days > 0 then
		return string.format("%dd %dh %dm", days, hours, minutes)
	elseif hours > 0 then
		return string.format("%dh %dm %ds", hours, minutes, seconds)
	elseif minutes > 0 then
		return string.format("%dm %ds", minutes, seconds)
	else
		return string.format("%ds", seconds)
	end
end

-- Format minutes/seconds (like "02:05" or "2m 5s")
function TimeFormatter.FormatMS(seconds: number, style: "mm:ss"|"m s")
	local minutes = math.floor(seconds / 60)
	local remainingSeconds = seconds % 60

	if style == "mm:ss" then
		return string.format("%02d:%02d", minutes, remainingSeconds)
	else
		return string.format("%dm %ds", minutes, remainingSeconds)
	end
end

function TimeFormatter.FormatHMS(seconds: number, style: "hh:mm:ss"|"h m s")
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local remainingSeconds = seconds % 60

	if style == "hh:mm:ss" then
		return string.format("%02d:%02d:%02d", hours, minutes, remainingSeconds)
	else
		return string.format("%dh %dm %ds", hours, minutes, remainingSeconds)
	end
end

-- Like FormatDHMS but always shows all 4 parts (e.g. "0d 0h 0m 0s"), never omitting zeroed units
function TimeFormatter.FormatDHMSFull(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local days = math.floor(seconds / 86400)
	seconds %= 86400
	local hours = math.floor(seconds / 3600)
	seconds %= 3600
	local minutes = math.floor(seconds / 60)
	seconds %= 60

	return string.format("%dd %dh %dm %ds", days, hours, minutes, seconds)
end

return TimeFormatter
