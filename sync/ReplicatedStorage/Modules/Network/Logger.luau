--@ Logger
--@ author: Keii
--@ made: 3/14/2026

local Logger = {}

Logger.Levels = {
	INFO = "INFO",
	WARN = "WARN",
	ERROR = "ERROR",
	DEBUG = "DEBUG",
}

local PREFIX = "[Network]"

-- Walks the call stack and returns info about the first frame outside of
-- Logger and Network internals -- i.e. the actual caller.
local function _getCallerInfo()
	for depth = 1, 24 do
		local ok, line, source, name = pcall(function()
			return debug.info(depth, "lsn")
		end)

		if not ok or not source then
			break
		end

		local s = tostring(source)

		-- Skip C frames, Logger itself, and Network internals
		if s == "[C]" then
			continue
		end
		if s:find("Logger", 1, true) then
			continue
		end
		if s:find("Network", 1, true) then
			continue
		end

		return {
			ShortName = s:match("([^./]+)$") or "System",
			FullName = s,
			Line = tonumber(line) or 0,
			FunctionName = (name and name ~= "") and name or "main",
		}
	end

	return {
		ShortName = "Unknown",
		FullName = "Unknown",
		Line = 0,
		FunctionName = "main",
	}
end

function Logger:Log(level: string, context: string, message: any)
	local info = _getCallerInfo()
	local formatted = string.format(
		"\n%s[%s](%s:%d)[%s][%s]: %s",
		PREFIX,
		os.date("%X"),
		info.FullName,
		info.Line,
		level,
		context,
		tostring(message)
	)

	if level == self.Levels.WARN then
		warn(formatted)
	else
		print(formatted)
	end
end

function Logger:ErrorLog(context: string, err: any)
	local info = _getCallerInfo()
	local message = tostring(err)
	local traceback = ""

	-- If it's a Promise error, use its captured trace
	if type(err) == "table" and err.trace then
		message = err.error or message
		traceback = err.trace
	else
		traceback = debug.traceback()
	end

	local formatted = string.format(
		"\n%s ERROR at %s:%d (Func: %s)\nContext: %s\nMessage: %s\nTraceback:\n%s",
		PREFIX,
		info.FullName,
		info.Line,
		info.FunctionName,
		context,
		message,
		traceback
	)

	warn(formatted)
end

return Logger
