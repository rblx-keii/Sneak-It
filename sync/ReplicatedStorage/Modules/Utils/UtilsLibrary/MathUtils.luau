--!strict
local Math = {}

--[=[
	Maps a value from one range [inMin, inMax] to another range [outMin, outMax].
	Useful for UI bars, health-to-color transitions, and XP sliders.
]=]
function Math.Map(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin)
end

--[=[
	Rounds a number to the nearest multiple of 'step'.
	Essential for grid-based placement or snapping objects.
]=]
function Math.Snap(value: number, step: number): number
	if step == 0 then
		return value
	end
	return math.round(value / step) * step
end

--[=[
	Rounds a number to a specific number of decimal places.
]=]
function Math.Round(value: number, decimalPlaces: number?): number
	local shift = 10 ^ (decimalPlaces or 0)
	return math.round(value * shift) / shift
end

--[=[
	Linearly interpolates between 'a' and 'b' by 't'.
]=]
function Math.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--[=[
	Returns 1 if the number is positive, -1 if negative, and 0 if zero.
]=]
function Math.Sign(value: number): number
	if value > 0 then
		return 1
	end
	if value < 0 then
		return -1
	end
	return 0
end

--[=[
	Checks if two numbers are approximately equal within a small epsilon.
	Crucial for physics calculations where floating point errors occur.
]=]
function Math.IsClose(a: number, b: number, epsilon: number?): boolean
	return math.abs(a - b) <= (epsilon or 0.00001)
end

return table.freeze(Math)
