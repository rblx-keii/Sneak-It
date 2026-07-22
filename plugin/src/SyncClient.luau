local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local Serializer = require(script.Parent.Serializer)
local JsonPretty = require(script.Parent.JsonPretty)
local Hash = require(script.Parent.Hash)

export type Status = "Disconnected" | "Connected" | "Pushing" | "Synced" | "Error"

local DEFAULT_PORT = 8123
local PING_INTERVAL = 3

local SyncClient = {}

local statusCallback: ((Status, string?) -> ())? = nil
local reachable = false
local lastSync: { status: Status, detail: string? }? = nil
local lastHashes: { [string]: string } = {}
local autoSyncToken = 0 -- incremented to invalidate any currently-running auto-sync loop

local function getPort(): number
	local ok, value = pcall(function()
		return plugin:GetSetting("MapifyPort")
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return DEFAULT_PORT
end

local function baseUrl(): string
	return `http://127.0.0.1:{getPort()}`
end

function SyncClient.GetPort(): number
	return getPort()
end

-- "Disconnected" always wins (most urgent); otherwise show the last push
-- result, or plain "Connected" if nothing has been pushed yet this session.
local function notify()
	if not statusCallback then
		return
	end
	if not reachable then
		statusCallback("Disconnected", nil)
	elseif lastSync then
		statusCallback(lastSync.status, lastSync.detail)
	else
		statusCallback("Connected", nil)
	end
end

function SyncClient.SetStatusCallback(callback: (Status, string?) -> ())
	statusCallback = callback
	notify()
end

function SyncClient.Ping(): boolean
	local ok, response = pcall(function()
		return HttpService:RequestAsync({ Url = baseUrl() .. "/ping", Method = "GET" })
	end)
	reachable = ok and response.Success
	notify()
	return reachable
end

-- Only ever-appended suffixes (never part of a sanitized instance name,
-- which only has its *trailing* dots stripped) — used to recover the
-- original top-level key from a file entry without mangling names that
-- legitimately contain a dot (e.g. "V1.2").
local KNOWN_FILE_SUFFIXES = { ".model.json", ".client.luau", ".server.luau", ".luau" }

local function entryKey(entry: Serializer.Entry): string?
	if entry.name then
		return entry.name
	end
	local fileName = entry.fileName
	if not fileName then
		return nil
	end
	for _, suffix in KNOWN_FILE_SUFFIXES do
		if fileName:sub(-#suffix) == suffix then
			return fileName:sub(1, -#suffix - 1)
		end
	end
	return fileName
end

-- Resolves `names` to live StarterGui instances, serializes them, and splits
-- the result into the full `selected` key list plus only the entries whose
-- content hash changed since the last successful push.
local function buildPushPayload(names: { string }): ({ string }, { { key: string, entry: any } })
	local instances = {}
	for _, name in names do
		local inst = StarterGui:FindFirstChild(name)
		if inst then
			table.insert(instances, inst)
		end
	end

	local entries = Serializer.serialize(instances)

	local selected = {}
	local changed = {}
	local selectedSet: { [string]: boolean } = {}
	for i, entry in entries do
		if not entry then
			continue
		end
		local key = entryKey(entry)
		if not key then
			continue
		end
		table.insert(selected, key)
		selectedSet[key] = true

		local hash = Hash.fnv1a(JsonPretty.encode(entry))
		if lastHashes[key] ~= hash then
			table.insert(changed, { key = key, entry = entry })
			lastHashes[key] = hash
		end
	end

	-- Forget hashes for keys no longer selected, so re-selecting later always
	-- resends fresh content instead of assuming it's unchanged.
	for key in lastHashes do
		if not selectedSet[key] then
			lastHashes[key] = nil
		end
	end

	return selected, changed
end

-- Pushes the given top-level StarterGui child names now, regardless of
-- whether auto-sync is running. Returns true on success.
function SyncClient.PushNow(names: { string }): boolean
	lastSync = { status = "Pushing" }
	notify()

	local selected, changed = buildPushPayload(names)

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = baseUrl() .. "/push",
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode({ selected = selected, changed = changed }),
		})
	end)

	if not ok then
		reachable = false
		lastSync = { status = "Error", detail = tostring(response) }
		notify()
		return false
	elseif not response.Success then
		lastSync = { status = "Error", detail = `HTTP {response.StatusCode}` }
		notify()
		return false
	end

	reachable = true
	lastSync = { status = "Synced", detail = tostring(os.time()) }
	notify()
	return true
end

function SyncClient.StartAutoSync(intervalSeconds: number, getSelectedNames: () -> { string })
	autoSyncToken += 1
	local token = autoSyncToken

	task.spawn(function()
		while token == autoSyncToken do
			SyncClient.PushNow(getSelectedNames())
			task.wait(intervalSeconds)
		end
	end)
end

function SyncClient.StopAutoSync()
	autoSyncToken += 1
end

function SyncClient.StartPingLoop()
	task.spawn(function()
		while true do
			SyncClient.Ping()
			task.wait(PING_INTERVAL)
		end
	end)
end

return SyncClient
