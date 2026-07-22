-- StringUtil.lua
-- Utility module for common string formatting operations used in front-end UI.
-- Pure functions only — no connections, no cleanup required.

--|| Types

export type SplitResult = { string }

--|| Module

local StringUtil = {}

-- [[ Capitalize ]]
-- Uppercases the first character of a string, lowercases the rest.
-- "asda" -> "Asda"
-- "hELLO wORLD" -> "Hello world"
function StringUtil.Capitalize(str: string): string
	if #str == 0 then return str end
	return string.upper(string.sub(str, 1, 1)) .. string.lower(string.sub(str, 2))
end

-- [[ PascalToWords ]]
-- Splits a PascalCase or camelCase string into space-separated words,
-- preserving the original casing of each word.
-- "AsdaDasda"  -> "Asda Dasda"
-- "sadaDsag"   -> "sada Dsag"   (camelCase: first segment left as-is)
-- "MyUIButton" -> "My U I Button"  (each uppercase letter is its own boundary)
function StringUtil.PascalToWords(str: string): string
	if #str == 0 then return str end
	-- Insert a space before every uppercase letter that follows a lowercase letter
	-- or before an uppercase letter followed by a lowercase (handles acronyms partially)
	local result = string.gsub(str, "(%l)(%u)", "%1 %2")
	-- Also handle sequences like "UIButton" -> "UI Button"
	result = string.gsub(result, "(%u+)(%u%l)", "%1 %2")
	return result
end

-- [[ CamelToWords ]]
-- Like PascalToWords, but also capitalizes the very first character.
-- "sadaDsag"    -> "Sada Dsag"
-- "myHealthBar" -> "My Health Bar"
function StringUtil.CamelToWords(str: string): string
	if #str == 0 then return str end
	local spaced = StringUtil.PascalToWords(str)
	return StringUtil.Capitalize(spaced)
end

-- [[ TrimWhitespace ]]
-- Removes leading and trailing whitespace (spaces, tabs, newlines).
-- "  hello  " -> "hello"
function StringUtil.TrimWhitespace(str: string): string
	return string.match(str, "^%s*(.-)%s*$") or str
end

-- [[ Truncate ]]
-- Shortens a string to `maxLen` characters, appending `ellipsis` if truncated.
-- Defaults: ellipsis = "…"
-- ("Hello World", 7) -> "Hello W…"
function StringUtil.Truncate(str: string, maxLen: number, ellipsis: string?): string
	local suffix = ellipsis or "…"
	if #str <= maxLen then return str end
	return string.sub(str, 1, maxLen) .. suffix
end

-- [[ PadLeft ]]
-- Pads a string on the left until it reaches `width`, using `padChar` (default "0").
-- ("42", 5, "0") -> "00042"
function StringUtil.PadLeft(str: string, width: number, padChar: string?): string
	local ch = padChar or "0"
	while #str < width do
		str = ch .. str
	end
	return str
end

-- [[ PadRight ]]
-- Pads a string on the right until it reaches `width`, using `padChar` (default " ").
-- ("hi", 5, "-") -> "hi---"
function StringUtil.PadRight(str: string, width: number, padChar: string?): string
	local ch = padChar or " "
	while #str < width do
		str = str .. ch
	end
	return str
end

-- [[ SplitWords ]]
-- Splits a string by a delimiter (default: any whitespace).
-- Returns a table of trimmed, non-empty substrings.
-- ("hello world foo", " ") -> {"hello", "world", "foo"}
function StringUtil.SplitWords(str: string, delimiter: string?): SplitResult
	local result: SplitResult = {}
	local pattern = delimiter and ("([^" .. delimiter .. "]+)") or "(%S+)"
	for word in string.gmatch(str, pattern) do
		table.insert(result, word)
	end
	return result
end

-- [[ FormatNumber ]]
-- Adds comma separators to an integer for display.
-- 1234567 -> "1,234,567"
-- Accepts both number and string input.
function StringUtil.FormatNumber(n: number): string
	local s = tostring(math.floor(n))
	-- Walk backwards inserting commas every 3 digits
	local result = string.gsub(s, "(%d)(%d%d%d)$", "%1,%2")
	-- Keep applying until stable (handles >6 digit numbers)
	local prev = ""
	while prev ~= result do
		prev = result
		result = string.gsub(result, "(%d)(%d%d%d),", "%1,%2,")
	end
	return result
end

-- [[ TitleCase ]]
-- Capitalizes the first letter of every word in a string.
-- "the quick brown fox" -> "The Quick Brown Fox"
function StringUtil.TitleCase(str: string): string
	return string.gsub(str, "(%a)([%w_']*)", function(first: string, rest: string): string
		return string.upper(first) .. string.lower(rest)
	end)
end

-- [[ StripNonAlpha ]]
-- Removes all characters except letters and spaces.
-- "H3llo, W0rld!" -> "Hllo Wrld"
function StringUtil.StripNonAlpha(str: string): string
	return string.gsub(str, "[^%a%s]", "")
end

-- [[ StartsWith / EndsWith ]]
-- Checks whether a string starts or ends with a given prefix/suffix.
function StringUtil.StartsWith(str: string, prefix: string): boolean
	return string.sub(str, 1, #prefix) == prefix
end

function StringUtil.EndsWith(str: string, suffix: string): boolean
	return suffix == "" or string.sub(str, -#suffix) == suffix
end

-- [[ Contains ]]
-- Returns true if `str` contains `substring` (plain match, no patterns).
function StringUtil.Contains(str: string, substring: string): boolean
	return string.find(str, substring, 1, true) ~= nil
end

-- [[ OrdinalSuffix ]]
-- Appends the correct English ordinal suffix to an integer.
-- 1 -> "1st", 2 -> "2nd", 3 -> "3rd", 4 -> "4th", 11 -> "11th", 13 -> "13th"
function StringUtil.OrdinalSuffix(n: number): string
	local abs = math.abs(math.floor(n))
	local lastTwo = abs % 100
	local lastOne = abs % 10
	local suffix: string
	-- 11, 12, 13 are special — always "th"
	if lastTwo >= 11 and lastTwo <= 13 then
		suffix = "th"
	elseif lastOne == 1 then
		suffix = "st"
	elseif lastOne == 2 then
		suffix = "nd"
	elseif lastOne == 3 then
		suffix = "rd"
	else
		suffix = "th"
	end
	return tostring(math.floor(n)) .. suffix
end

-- [[ ToSnakeCase ]]
-- Converts a PascalCase, camelCase, or space-separated string to snake_case.
-- "MyHealthBar"  -> "my_health_bar"
-- "camelCase"    -> "camel_case"
-- "Hello World"  -> "hello_world"
function StringUtil.ToSnakeCase(str: string): string
	-- Split on uppercase boundaries (same as PascalToWords)
	local result = string.gsub(str, "(%l)(%u)", "%1_%2")
	result = string.gsub(result, "(%u+)(%u%l)", "%1_%2")
	-- Replace spaces with underscores, then lowercase everything
	result = string.gsub(result, "%s+", "_")
	return string.lower(result)
end

-- [[ FromSnakeCase ]]
-- Converts a snake_case string to Title Case words.
-- "my_health_bar" -> "My Health Bar"
-- "coin_count"    -> "Coin Count"
function StringUtil.FromSnakeCase(str: string): string
	return string.gsub(str, "([^_]+)", function(word: string): string
		return StringUtil.Capitalize(word)
	end):gsub("_", " ")
end

-- [[ ToKebabCase ]]
-- Converts a PascalCase, camelCase, or space-separated string to kebab-case.
-- "MyHealthBar"  -> "my-health-bar"
-- "camelCase"    -> "camel-case"
-- "Hello World"  -> "hello-world"
function StringUtil.ToKebabCase(str: string): string
	-- Reuse snake_case logic, then swap underscores for hyphens
	local snake = StringUtil.ToSnakeCase(str)
	return string.gsub(snake, "_", "-")
end

-- [[ FromKebabCase ]]
-- Converts a kebab-case string to Title Case words.
-- "my-health-bar" -> "My Health Bar"
-- "coin-count"    -> "Coin Count"
function StringUtil.FromKebabCase(str: string): string
	return string.gsub(str, "([^-]+)", function(word: string): string
		return StringUtil.Capitalize(word)
	end):gsub("-", " ")
end

return StringUtil