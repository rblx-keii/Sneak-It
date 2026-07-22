--@ NetworkLite
--@ author: Keii
--@ made: 3/26/2026

--|| SERVICES
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

--|| DEPENDENCIES
local Signal = require(script.Signal)
local Promise = require(script.Promise)
local Logger = require(script.Logger)

--|| TYPES
export type Cleanup = { Disconnect: (self: Cleanup) -> () }

--|| CONFIGURATION
local DEBUG_TOGGLE = false -- set false to silence non-error logs
local VERBOSE_FLUSH = false -- set true ONLY when diagnosing bandwidth -- logs every frame flush (expensive)
local MAIN_KEY = "__main"
local RELIABLE_NAME = "_R"
local UNRELIABLE_NAME = "_U"
local SYNC_NAME = "_Sync"
local INVOKE_NAME = "_Invoke"
local REMOTE_FOLDER = "_Remotes"
local MAX_EVENT_IDS = 255

--|| CONSTANTS
local IS_SERVER = RunService:IsServer()

--|| MODULE TABLES
local Local = {}
local Shared = {}

--|| INTERNAL STATE

-- eventId registry: "event\0key" -> u16 id (1-indexed)
-- ids are assigned server-side and synced to clients.
local _nameToId: { [string]: number } = {} -- "event\0key" -> id
local _idToName: { [number]: string } = {} -- id -> "event\0key"
local _nextId = 1

-- Per event-key entry in the registry.
-- { LocalSignal, IsFunction, IsStub, Callback? }
local _registry: { [string]: { [string]: any } } = {}

-- In-process only signals -- no remote, no serialization.
local _localRegistry: { [string]: { [string]: any } } = {}

-- Outbound batch queues.
-- Server: per-player queues  { [Player]: { id, payload, ... } }
-- Client: flat queue          { id, payload, ... }
local _reliableQueue: any = IS_SERVER and {} or {}
local _unreliableQueue: any = IS_SERVER and {} or {}

-- Keys registered this frame -- fires to these are deferred by one frame so the
-- sync message arrives before any data packet using that ID.
local _newlyRegistered: { [string]: boolean } = {}

-- Connection cleanup table
local _connections: { [string]: Cleanup } = {}

-- Remote references.
local _reliable: RemoteEvent
local _unreliable: UnreliableRemoteEvent
local _invokeRemote: RemoteFunction
local _sync: RemoteEvent

-- True after the server's initial bind phase completes (end of first frame).
-- Incremental per-player sync fires are suppressed until then -- PlayerAdded
-- sends the full table in one shot instead.
local _serverReady = false

-- Client sync state (set inside the client branch below).
local _synced = false
local _clientReady = false -- true after the module loader calls SignalReady()
local _incomingBuffer: { { any } } = {} -- batches received before SignalReady
local _pendingFires: { { event: string, key: string, data: any } } = {}

-- Fires(nameKey) whenever a new ID is written to the registry.
-- Consumers (InvokeServer, pending-fire flush) react to this instead of polling.
local _idRegistered = Signal.new()

-- Server-side: per-player readiness gate.
-- Players start as not-ready; set to true when the client ACKs the sync.
local _playerReady: { [Player]: boolean } = {}

-- Reliable packets queued before the player was ready.
-- Flushed in one shot when the ACK arrives, then set to nil.
local _heldQueue: { [Player]: { any } } = {}

-- Fires(player) when a player becomes ready.
-- Used by InvokeClient to reactively wait instead of polling.
local _playerReadySignal = Signal.new()

--|| REMOTE INFRASTRUCTURE

local function _getRemoteFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER)
	if not folder and IS_SERVER then
		folder = Instance.new("Folder")
		folder.Name = REMOTE_FOLDER
		folder.Parent = ReplicatedStorage
	elseif not folder then
		folder = ReplicatedStorage:WaitForChild(REMOTE_FOLDER, 10)
	end
	return folder :: Folder
end

local function _getOrCreate(name: string, className: string): any
	local folder = _getRemoteFolder()
	local inst = folder:FindFirstChild(name)
	if not inst and IS_SERVER then
		inst = Instance.new(className)
		inst.Name = name
		inst.Parent = folder
	elseif not inst then
		inst = folder:WaitForChild(name, 10)
	end
	return inst
end

local function _ensureRemotes()
	if _reliable then
		return
	end
	_reliable = _getOrCreate(RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
	_unreliable = _getOrCreate(UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
	_invokeRemote = _getOrCreate(INVOKE_NAME, "RemoteFunction") :: RemoteFunction
	_sync = _getOrCreate(SYNC_NAME, "RemoteEvent") :: RemoteEvent
end

--|| EVENT ID HELPERS

local function _makeKey(event: string, key: string): string
	return event .. "\0" .. key
end

-- Server assigns IDs; client receives them via sync.
local function _assignId(event: string, key: string): number
	local k = _makeKey(event, key)
	if _nameToId[k] then
		return _nameToId[k]
	end
	assert(_nextId <= MAX_EVENT_IDS, "[NetworkLite] Exceeded max event IDs (255)")
	local id = _nextId
	_nextId += 1
	_nameToId[k] = id
	_idToName[id] = k
	return id
end

local function _resolveId(event: string, key: string): number?
	return _nameToId[_makeKey(event, key)]
end

--|| ARG RESOLUTION HELPERS
-- Handles the __main shorthand:
--   BindEvent("Remote", callback)         -> event="Remote", key="__main", callback=callback
--   BindEvent("Remote", "Key", callback)  -> event="Remote", key="Key",    callback=callback

local function _resolveEventKey(event: string, keyOrCallback: any, maybeCallback: any): (string, string, any)
	if typeof(keyOrCallback) == "function" then
		return event, MAIN_KEY, keyOrCallback
	end
	return event, keyOrCallback :: string, maybeCallback
end

-- For fire methods:
--   FireServer("Remote", data)         -> event="Remote", key="__main", data=data
--   FireServer("Remote", "Key", data)  -> event="Remote", key="Key",    data=data

local function _resolveEventKeyData(event: string, keyOrData: any, maybeData: any): (string, string, any)
	if typeof(keyOrData) == "string" then
		return event, keyOrData, maybeData
	end
	return event, MAIN_KEY, keyOrData
end

--|| BATCH DISPATCH

local function _enqueueReliable(target: any, id: number, payload: any)
	if IS_SERVER then
		if not _reliableQueue[target] then
			_reliableQueue[target] = {}
		end
		local q = _reliableQueue[target]
		q[#q + 1] = id
		q[#q + 1] = payload
	else
		local q = _reliableQueue
		q[#q + 1] = id
		q[#q + 1] = payload
	end
end

local function _enqueueUnreliable(target: any, id: number, payload: any)
	if IS_SERVER then
		if not _unreliableQueue[target] then
			_unreliableQueue[target] = {}
		end
		local q = _unreliableQueue[target]
		q[#q + 1] = id
		q[#q + 1] = payload
	else
		local q = _unreliableQueue
		q[#q + 1] = id
		q[#q + 1] = payload
	end
end

-- Flush all queued packets once per frame.
local function _flushQueues()
	_ensureRemotes()

	-- Helper to estimate bytes and identify events in a batch for debug logging.
	local function _describeBatch(batch: { any }): (number, string)
		local bytes = 9 + 2 -- remote overhead + table overhead
		local events = {}
		local i = 1
		while i <= #batch do
			local id = batch[i]
			local payload = batch[i + 1]
			i += 2
			-- identify event:key from ID
			local nameKey = _idToName[id]
			if nameKey then
				local sep = string.find(nameKey, "\0", 1, true) :: number
				events[#events + 1] = string.sub(nameKey, 1, sep - 1) .. ":" .. string.sub(nameKey, sep + 1)
			else
				events[#events + 1] = "id=" .. tostring(id)
			end
			-- estimate payload bytes
			local pt = typeof(payload)
			if pt == "string" then
				bytes += #payload + 2
			elseif pt == "number" then
				bytes += 9
			elseif pt == "table" then
				local function estimateTable(t: any, depth: number): number
					if depth > 4 then
						return 2
					end
					local n = 2
					for _, v in t do
						local vt = typeof(v)
						if vt == "string" then
							n += #v + 2
						elseif vt == "number" then
							n += 9
						elseif vt == "boolean" then
							n += 2
						elseif vt == "table" then
							n += estimateTable(v, depth + 1)
						else
							n += 4
						end
					end
					return n
				end
				bytes += estimateTable(payload, 0)
			else
				bytes += 4
			end
		end
		return bytes, table.concat(events, ", ")
	end

	if IS_SERVER then
		for player, batch in _reliableQueue do
			if #batch > 0 then
				if _playerReady[player] then
					if VERBOSE_FLUSH then
						local bytes, evts = _describeBatch(batch)
						Logger:Log(
							Logger.Levels.DEBUG,
							"Flush",
							string.format(
								"-> %s reliable [%s]: ~%d bytes (%d packets)",
								player.Name,
								evts,
								bytes,
								#batch / 2
							)
						)
					end
					_reliable:FireClient(player, batch)
				else
					-- Hold until client ACKs the sync
					local held = _heldQueue[player]
					if held then
						for _, v in batch do
							held[#held + 1] = v
						end
					end
				end
			end
		end
		for player, batch in _unreliableQueue do
			if #batch > 0 then
				if _playerReady[player] then
					if VERBOSE_FLUSH then
						local bytes, evts = _describeBatch(batch)
						Logger:Log(
							Logger.Levels.DEBUG,
							"Flush",
							string.format(
								"-> %s unreliable [%s]: ~%d bytes (%d packets)",
								player.Name,
								evts,
								bytes,
								#batch / 2
							)
						)
					end
					_unreliable:FireClient(player, batch)
				end
				-- Not ready → silently drop (unreliable by design)
			end
		end
		table.clear(_reliableQueue)
		table.clear(_unreliableQueue)
	else
		if #_reliableQueue > 0 then
			if VERBOSE_FLUSH then
				local bytes, evts = _describeBatch(_reliableQueue)
				Logger:Log(
					Logger.Levels.DEBUG,
					"Flush",
					string.format("^ reliable [%s]: ~%d bytes (%d packets)", evts, bytes, #_reliableQueue / 2)
				)
			end
			_reliable:FireServer(_reliableQueue)
			table.clear(_reliableQueue)
		end
		if #_unreliableQueue > 0 then
			if VERBOSE_FLUSH then
				local bytes, evts = _describeBatch(_unreliableQueue)
				Logger:Log(
					Logger.Levels.DEBUG,
					"Flush",
					string.format("^ unreliable [%s]: ~%d bytes (%d packets)", evts, bytes, #_unreliableQueue / 2)
				)
			end
			_unreliable:FireServer(_unreliableQueue)
			table.clear(_unreliableQueue)
		end
	end
end

--|| INCOMING DISPATCH

local function _dispatchBatch(player: Player?, batch: { any })
	local i = 1
	while i <= #batch do
		local id = batch[i]
		local payload = batch[i + 1]
		i += 2

		local nameKey = _idToName[id]
		if not nameKey then
			if DEBUG_TOGGLE then
				Logger:ErrorLog("Dispatcher", "Unknown event ID: " .. tostring(id))
			end
			continue
		end

		local sep = string.find(nameKey, "\0", 1, true) :: number
		local event = string.sub(nameKey, 1, sep - 1)
		local key = string.sub(nameKey, sep + 1)

		local channel = _registry[event]
		local entry = channel and channel[key]
		if not entry or entry.IsFunction or entry.IsStub then
			continue
		end

		if IS_SERVER then
			entry.LocalSignal:Fire(player, payload)
		else
			entry.LocalSignal:Fire(payload)
		end
	end
end

--|| SYNC
-- Wire format (compressed):
-- [ u16 eventCount ]
--   [ u16 eventNameLen ][ eventName bytes ]
--   [ u16 keyCount ]
--     [ u16 keyNameLen ][ keyName bytes ][ u16 id ]

local function _buildSyncPayload(): buffer
	-- Group keys by event name to deduplicate the event string on the wire.
	local byEvent: { [string]: { { key: string, id: number } } } = {}
	for nameKey, id in _nameToId do
		local sep = string.find(nameKey, "\0", 1, true) :: number
		local event = string.sub(nameKey, 1, sep - 1)
		local key = string.sub(nameKey, sep + 1)
		if not byEvent[event] then
			byEvent[event] = {}
		end
		byEvent[event][#byEvent[event] + 1] = { key = key, id = id }
	end

	-- Calculate exact byte size needed.
	local size = 2 -- u16 event count
	for event, keys in byEvent do
		size += 2 + #event -- u16 len + event bytes
		size += 2 -- u16 key count
		for _, entry in keys do
			size += 2 + #entry.key + 2 -- u16 len + key bytes + u16 id
		end
	end

	local b = buffer.create(size)
	local offset = 0

	local eventList = {}
	for event in byEvent do
		eventList[#eventList + 1] = event
	end

	buffer.writeu16(b, offset, #eventList)
	offset += 2

	for _, event in eventList do
		local keys = byEvent[event]
		buffer.writeu16(b, offset, #event)
		buffer.writestring(b, offset + 2, (event :: any))
		offset += 2 + #event

		buffer.writeu16(b, offset, #keys)
		offset += 2

		for _, entry in keys do
			buffer.writeu16(b, offset, #entry.key)
			buffer.writestring(b, offset + 2, entry.key)
			buffer.writeu16(b, offset + 2 + #entry.key, entry.id)
			offset += 2 + #entry.key + 2
		end
	end

	return b
end

local function _parseSyncPayload(b: buffer)
	-- buffer arrives as string over the wire -- convert back.
	if typeof(b) == "string" then
		b = buffer.fromstring(b :: any)
	end

	local offset = 0
	local eventCount = buffer.readu16(b, offset)
	offset += 2

	for _ = 1, eventCount do
		local eventLen = buffer.readu16(b, offset)
		local event = buffer.readstring(b, offset + 2, eventLen)
		offset += 2 + eventLen

		local keyCount = buffer.readu16(b, offset)
		offset += 2

		for _ = 1, keyCount do
			local keyLen = buffer.readu16(b, offset)
			local key = buffer.readstring(b, offset + 2, keyLen)
			local id = buffer.readu16(b, offset + 2 + keyLen)
			offset += 2 + keyLen + 2

			local nameKey = _makeKey(event, key)
			_nameToId[nameKey] = id
			_idToName[id] = nameKey
			_idRegistered:Fire(nameKey)

			if not _registry[event] then
				_registry[event] = {}
			end
			if not _registry[event][key] then
				_registry[event][key] = {
					LocalSignal = Signal.new(),
					IsFunction = false,
					IsStub = true,
				}
			end

			if DEBUG_TOGGLE then
				Logger:Log(Logger.Levels.DEBUG, event, "Synced ID " .. id .. " for key: " .. key)
			end
		end
	end
end

-- Sends only newly added keys to already-connected players (post-startup).
local function _syncNewKey(nameKey: string, id: number)
	if not _serverReady then
		if DEBUG_TOGGLE then
			local sep = string.find(nameKey, "\0", 1, true) :: number
			local event = string.sub(nameKey, 1, sep - 1)
			local key = string.sub(nameKey, sep + 1)
			Logger:Log(Logger.Levels.DEBUG, "Sync", "Deferred (startup) ID " .. id .. " for " .. event .. ":" .. key)
		end
		return
	end
	if #Players:GetPlayers() == 0 then
		return
	end

	local sep = string.find(nameKey, "\0", 1, true) :: number
	local event = string.sub(nameKey, 1, sep - 1)
	local key = string.sub(nameKey, sep + 1)

	local size = 2 + 2 + #event + 2 + 2 + #key + 2
	local b = buffer.create(size)
	local o = 0
	buffer.writeu16(b, o, 1)
	o += 2
	buffer.writeu16(b, o, #event)
	buffer.writestring(b, o + 2, event)
	o += 2 + #event
	buffer.writeu16(b, o, 1)
	o += 2
	buffer.writeu16(b, o, #key)
	buffer.writestring(b, o + 2, key)
	buffer.writeu16(b, o + 2 + #key, id)

	local payload = buffer.tostring(b)
	if DEBUG_TOGGLE then
		Logger:Log(
			Logger.Levels.DEBUG,
			"Sync",
			string.format(
				"-> incremental sync %s:%s (ID %d): ~%d bytes to %d players",
				event,
				key,
				id,
				9 + #payload + 2,
				#Players:GetPlayers()
			)
		)
	end
	for _, player in Players:GetPlayers() do
		_sync:FireClient(player, payload)
	end
end

-- Auto-registers an event key on first fire if it hasn't been registered yet.
-- Removes the need for manual RegisterEvent calls on send-only keys.
local function _autoRegister(event: string, key: string)
	if _resolveId(event, key) then
		return
	end

	if not _registry[event] then
		_registry[event] = {}
	end
	if not _registry[event][key] then
		_registry[event][key] = {
			LocalSignal = Signal.new(),
			IsFunction = false,
		}
	end

	if IS_SERVER then
		local id = _assignId(event, key)
		_syncNewKey(_makeKey(event, key), id)
		-- Mark this key as newly registered so fire methods defer by one frame,
		-- giving the sync message time to arrive before any data using this ID.
		_newlyRegistered[_makeKey(event, key)] = true
		task.defer(function()
			_newlyRegistered[_makeKey(event, key)] = nil
		end)
	end

	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, event, "Auto-registered event: " .. key)
	end
end

--|| CLIENT PENDING-FIRE QUEUE

local function _tryFlushPending()
	local remaining = {}
	for _, pending in _pendingFires do
		local id = _resolveId(pending.event, pending.key)
		if id then
			_enqueueReliable(nil, id, pending.data)
			if DEBUG_TOGGLE then
				Logger:Log(Logger.Levels.DEBUG, "Flushed pending fire:", `Event: {pending.event} | Key: {pending.key}`)
			end
		else
			remaining[#remaining + 1] = pending
		end
	end
	_pendingFires = remaining
end

local function _queuePendingFire(event: string, key: string, data: any)
	_pendingFires[#_pendingFires + 1] = { event = event, key = key, data = data }
	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, event, "Queued pending fire for key: " .. key .. " (waiting for sync)")
	end
end

--|| INITIALIZE

function Local._initialize()
	_ensureRemotes()

	if IS_SERVER then
		task.defer(function()
			_serverReady = true
		end)

		RunService.Heartbeat:Connect(_flushQueues)

		_reliable.OnServerEvent:Connect(function(player: Player, batch: { any })
			_dispatchBatch(player, batch)
		end)

		_unreliable.OnServerEvent:Connect(function(player: Player, batch: { any })
			_dispatchBatch(player, batch)
		end)

		Players.PlayerRemoving:Connect(function(player: Player)
			_playerReady[player] = nil
			_heldQueue[player] = nil
			_reliableQueue[player] = nil
			_unreliableQueue[player] = nil
		end)

		-- Send the full compressed ID table once per joining player.
		Players.PlayerAdded:Connect(function(player: Player)
			_playerReady[player] = false
			_heldQueue[player] = {}
			local syncBuf = _buildSyncPayload()
			local syncStr = buffer.tostring(syncBuf)
			if DEBUG_TOGGLE then
				Logger:Log(
					Logger.Levels.DEBUG,
					"Sync",
					string.format("-> %s sync payload: ~%d bytes (%d keys)", player.Name, 9 + #syncStr + 2, _nextId - 1)
				)
			end
			_sync:FireClient(player, syncStr)
		end)

		-- Listen for client sync ACK — gate all server→client traffic until received.
		_sync.OnServerEvent:Connect(function(player: Player)
			if _playerReady[player] then
				return -- Already ACKed (idempotent guard)
			end
			_playerReady[player] = true
			_playerReadySignal:Fire(player)

			local held = _heldQueue[player]
			if held and #held > 0 then
				if DEBUG_TOGGLE then
					Logger:Log(
						Logger.Levels.DEBUG,
						"Sync",
						string.format(
							"-> %s ready — flushing %d held packets",
							player.Name,
							#held / 2
						)
					)
				end
				_reliable:FireClient(player, held)
			end
			_heldQueue[player] = nil
		end)

		_invokeRemote.OnServerInvoke = function(player: Player, id: number, payload: any): typeof(Promise.new())
			local nameKey = _idToName[id]
			if not nameKey then
				return nil
			end

			local sep = string.find(nameKey, "\0", 1, true) :: number
			local event = string.sub(nameKey, 1, sep - 1)
			local key = string.sub(nameKey, sep + 1)

			local entry = _registry[event] and _registry[event][key]
			if not entry or not entry.IsFunction then
				return nil
			end

			return entry.Callback(player, payload)
		end
	else
		RunService.RenderStepped:Connect(_flushQueues)

		_reliable.OnClientEvent:Connect(function(batch: { any })
			if _clientReady then
				_dispatchBatch(nil, batch)
			else
				_incomingBuffer[#_incomingBuffer + 1] = batch
			end
		end)

		_unreliable.OnClientEvent:Connect(function(batch: { any })
			if _clientReady then
				_dispatchBatch(nil, batch)
			else
				_incomingBuffer[#_incomingBuffer + 1] = batch
			end
		end)

		_sync.OnClientEvent:Connect(function(payload: any)
			_parseSyncPayload(payload)
			_synced = true
			_tryFlushPending()
			_sync:FireServer() -- ACK immediately so server traffic flows freely
		end)

		_invokeRemote.OnClientInvoke = function(id: number, payload: any): typeof(Promise.new())
			local nameKey = _idToName[id]
			if not nameKey then
				return nil
			end

			local sep = string.find(nameKey, "\0", 1, true) :: number
			local event = string.sub(nameKey, 1, sep - 1)
			local key = string.sub(nameKey, sep + 1)

			local entry = _registry[event] and _registry[event][key]
			if not entry or not entry.IsFunction then
				return nil
			end

			return entry.Callback(payload)
		end
	end
end

--|| SHARED API

-- BindLocalEvent: purely in-process, no remote, no serialization.
-- Same env only. Ideal for client-side prediction.
function Shared:BindLocalEvent(event: string, keyOrCallback: any, maybeCallback: any): Cleanup
	local _, key, callback = _resolveEventKey(event, keyOrCallback, maybeCallback)

	if not _localRegistry[event] then
		_localRegistry[event] = {}
	end
	if not _localRegistry[event][key] then
		_localRegistry[event][key] = Signal.new()
	end

	local guid = HttpService:GenerateGUID(false)
	local conn = _localRegistry[event][key]:Connect(callback)
	local cleanup: Cleanup = {
		Disconnect = function(self: Cleanup)
			conn:Disconnect()
			_connections[guid] = nil
		end,
	}
	
	_connections[guid] = cleanup
	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, event, "Bound local event: " .. key)
	end
	return cleanup
end

-- BindLocalEventOnce: same as BindLocalEvent but auto-disconnects after the first fire.
function Shared:BindLocalEventOnce(event: string, keyOrCallback: any, maybeCallback: any): Cleanup
	local _, key, callback = _resolveEventKey(event, keyOrCallback, maybeCallback)

	if not _localRegistry[event] then
		_localRegistry[event] = {}
	end
	if not _localRegistry[event][key] then
		_localRegistry[event][key] = Signal.new()
	end

	local guid = HttpService:GenerateGUID(false)
	local conn = _localRegistry[event][key]:Once(function(...)
		_connections[guid] = nil
		callback(...)
	end)
	local cleanup: Cleanup = {
		Disconnect = function(self: Cleanup)
			conn:Disconnect()
			_connections[guid] = nil
		end,
	}
	_connections[guid] = cleanup
	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, event, "Bound local event (once): " .. key)
	end
	return cleanup
end

function Shared:FireLocal(event: string, keyOrData: any, maybeData: any)
	local _, key, data = _resolveEventKeyData(event, keyOrData, maybeData)
	local channel = _localRegistry[event]
	local signal = channel and channel[key]
	if signal then
		signal:Fire(data)
	elseif DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, event, "FireLocal: no listeners for key: " .. key)
	end
end

-- BindEvent: cross-env listener. Fires when the remote is received from the other side.
function Shared:BindEvent(event: string, keyOrCallback: any, maybeCallback: any): Cleanup
	local _, key, callback = _resolveEventKey(event, keyOrCallback, maybeCallback)

	if not _registry[event] then
		_registry[event] = {}
	end

	if not _registry[event][key] then
		_registry[event][key] = {
			LocalSignal = Signal.new(),
			IsFunction = false,
		}
	else
		local entry = _registry[event][key]
		entry.IsFunction = false
		entry.IsStub = nil
	end

	-- Assign and sync ID (server only -- clients receive IDs via _sync).
	if IS_SERVER then
		local id = _assignId(event, key)
		_syncNewKey(_makeKey(event, key), id)
	end

	local guid = HttpService:GenerateGUID(false)
	local conn = _registry[event][key].LocalSignal:Connect(callback)
	local cleanup: Cleanup = {
		Disconnect = function(self: Cleanup)
			conn:Disconnect()
			_connections[guid] = nil
		end,
	}
	_connections[guid] = cleanup
	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, "Bind Event", `Event: {event} | Key: {key}`)
	end
	return cleanup
end

-- BindEventOnce: same as BindEvent but auto-disconnects after the first fire.
function Shared:BindEventOnce(event: string, keyOrCallback: any, maybeCallback: any): Cleanup
	local _, key, callback = _resolveEventKey(event, keyOrCallback, maybeCallback)

	if not _registry[event] then
		_registry[event] = {}
	end

	if not _registry[event][key] then
		_registry[event][key] = {
			LocalSignal = Signal.new(),
			IsFunction = false,
		}
	else
		local entry = _registry[event][key]
		entry.IsFunction = false
		entry.IsStub = nil
	end

	if IS_SERVER then
		local id = _assignId(event, key)
		_syncNewKey(_makeKey(event, key), id)
	end

	local guid = HttpService:GenerateGUID(false)
	local conn = _registry[event][key].LocalSignal:Once(function(...)
		_connections[guid] = nil
		callback(...)
	end)
	local cleanup: Cleanup = {
		Disconnect = function(self: Cleanup)
			conn:Disconnect()
			_connections[guid] = nil
		end,
	}
	_connections[guid] = cleanup
	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, "Bind Event (once)", `Event: {event} | Key: {key}`)
	end
	return cleanup
end

-- RegisterEvent: registers a send-only key so it gets an ID and is synced to clients,
-- without attaching a callback. Use this on the server for keys it only fires, never listens to,
-- and on the client for keys it only fires to the server.
function Shared:RegisterEvent(event: string, keyOrNil: string?)
	local key = keyOrNil or MAIN_KEY

	if not _registry[event] then
		_registry[event] = {}
	end
	if not _registry[event][key] then
		_registry[event][key] = {
			LocalSignal = Signal.new(),
			IsFunction = false,
		}
	end

	if IS_SERVER then
		local id = _assignId(event, key)
		_syncNewKey(_makeKey(event, key), id)
	end

	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, event, "Registered event: " .. key)
	end
end

-- BindFunction: cross-env invoke handler.
function Shared:BindFunction(event: string, keyOrCallback: any, maybeCallback: any): Cleanup
	local _, key, callback = _resolveEventKey(event, keyOrCallback, maybeCallback)

	if not _registry[event] then
		_registry[event] = {}
	end
	_registry[event][key] = {
		Callback = callback,
		IsFunction = true,
	}

	if IS_SERVER then
		local id = _assignId(event, key)
		_syncNewKey(_makeKey(event, key), id)
	end

	local guid = HttpService:GenerateGUID(false)
	local cleanup: Cleanup = {
		Disconnect = function(self: Cleanup)
			_registry[event][key] = nil
			_connections[guid] = nil
		end,
	}
	_connections[guid] = cleanup
	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, "Bound Function", `Function: {event} | Key: {key}`)
	end
	return cleanup
end

--- Signals that all client modules have finished Init and their listeners
--- are bound. Flushes any incoming packets that arrived before listeners
--- were ready. Call once from the module loader after client Init completes.
function Shared:SignalReady()
	if IS_SERVER then return end
	_clientReady = true
	-- Replay every batch that arrived while listeners were still binding.
	for _, batch in _incomingBuffer do
		_dispatchBatch(nil, batch)
	end
	table.clear(_incomingBuffer)
	if DEBUG_TOGGLE then
		Logger:Log(Logger.Levels.DEBUG, "SignalReady", "Client ready — dispatched buffered packets")
	end
end

--- OBFUSCATOR
local Obfuscator = require(script.Obsfucator)
Shared.Obfuscator = Obfuscator

---------------------------------------------------------------------
--|| SERVER API
---------------------------------------------------------------------
if IS_SERVER then
	-- Enqueues a fire to all clients. Flushed end of frame.
	function Shared:FireAll(event: string, keyOrData: any, maybeData: any)
		local _, key, data = _resolveEventKeyData(event, keyOrData, maybeData)
		_autoRegister(event, key)
		local id = _resolveId(event, key)

		local nameKey = _makeKey(event, key)
		if _newlyRegistered[nameKey] then
			task.defer(function()
				for _, player in ipairs(Players:GetPlayers()) do
					_enqueueReliable(player, id, data)
				end
			end)
		else
			for _, player in ipairs(Players:GetPlayers()) do
				_enqueueReliable(player, id, data)
			end
		end
	end

	-- Same as FireAll but skips one or more players.
	-- blacklist: Player | { Player }
	function Shared:FireAllExcept(event: string, blacklist: Player | { Player }, keyOrData: any, maybeData: any)
		local _, key, data = _resolveEventKeyData(event, keyOrData, maybeData)
		_autoRegister(event, key)
		local id = _resolveId(event, key)

		-- Build a fast lookup set from the blacklist.
		local excluded: { [Player]: boolean } = {}
		if typeof(blacklist) == "Instance" then
			excluded[blacklist :: Player] = true
		else
			for _, plr in ipairs(blacklist :: { Player }) do
				excluded[plr] = true
			end
		end

		local nameKey = _makeKey(event, key)
		if _newlyRegistered[nameKey] then
			task.defer(function()
				for _, player in ipairs(Players:GetPlayers()) do
					if not excluded[player] then
						_enqueueReliable(player, id, data)
					end
				end
			end)
		else
			for _, player in ipairs(Players:GetPlayers()) do
				if not excluded[player] then
					_enqueueReliable(player, id, data)
				end
			end
		end
	end

	-- Enqueues a fire to one or more specific clients.
	function Shared:FireClient(event: string, playerOrTable: any, keyOrData: any, maybeData: any)
		local key: string
		local data: any

		if typeof(keyOrData) == "string" then
			key = keyOrData
			data = maybeData
		else
			key = MAIN_KEY
			data = keyOrData
		end

		_autoRegister(event, key)
		local id = _resolveId(event, key)

		local nameKey = _makeKey(event, key)
		local function doFire()
			if typeof(playerOrTable) == "Instance" then
				_enqueueReliable(playerOrTable, id, data)
			else
				for _, plr in ipairs(playerOrTable) do
					_enqueueReliable(plr, id, data)
				end
			end
		end

		if _newlyRegistered[nameKey] then
			task.defer(doFire)
		else
			doFire()
		end
	end

	-- Invoke a client (RemoteFunction -- not batched).
	function Shared:InvokeClient(event: string, player: Player, keyOrData: any, maybeData: any): typeof(Promise.new())
		local key: string
		local data: any

		if typeof(keyOrData) == "string" then
			key = keyOrData
			data = maybeData
		else
			key = MAIN_KEY
			data = keyOrData
		end

		_autoRegister(event, key)
		local id = _resolveId(event, key)

		return Promise.new(function(resolve, reject)
			-- Wait for the player to be synced and ready before invoking.
			if not _playerReady[player] then
				local conn
				local ready = false

				conn = _playerReadySignal:Connect(function(p: Player)
					if p == player then
						ready = true
						if conn then
							conn:Disconnect()
						end
					end
				end)

				-- Re-check after connect (race guard)
				if _playerReady[player] then
					ready = true
					conn:Disconnect()
				end

				if not ready then
					local waited = 0
					while not ready and waited < 15 do
						task.wait(0.1)
						waited += 0.1
					end
					if not ready then
						conn:Disconnect()
						reject("Timed out waiting for player ready: " .. player.Name)
						return
					end
				end
			end

			local ok, res = pcall(_invokeRemote.InvokeClient, _invokeRemote, player, id, data)
			if ok then
				resolve(res)
			else
				reject(res)
			end
		end):catch(function(err)
			Logger:ErrorLog("InvokeClient:" .. key, err)
			return Promise.reject(err)
		end)
	end

	---------------------------------------------------------------------
	--|| CLIENT API
	---------------------------------------------------------------------
else
	-- Enqueues a fire to the server. Flushed end of frame.
	-- If the client hasn't synced with the server yet, queues for retry after sync.
	function Shared:FireServer(event: string, keyOrData: any, maybeData: any)
		local _, key, data = _resolveEventKeyData(event, keyOrData, maybeData)

		local id = _resolveId(event, key)
		if not id then
			_queuePendingFire(event, key, data)
			return
		end

		_enqueueReliable(nil, id, data)
	end

	-- Invoke the server (RemoteFunction -- not batched).
	function Shared:InvokeServer(event: string, keyOrData: any, maybeData: any): typeof(Promise.new())
		local _, key, data = _resolveEventKeyData(event, keyOrData, maybeData)
		local targetKey = _makeKey(event, key)

		return Promise.new(function(resolve, reject)
			local id = _resolveId(event, key)

			-- If the ID hasn't arrived yet, wait reactively for it.
			if not id then
				local conn
				local resolved = false

				conn = _idRegistered:Connect(function(nameKey: string)
					if nameKey == targetKey then
						resolved = true
						if conn then
							conn:Disconnect()
						end
					end
				end)

				-- Re-check in case the ID arrived between the first check and the connect.
				id = _resolveId(event, key)
				if id then
					resolved = true
					conn:Disconnect()
				end

				if not resolved then
					local waited = 0
					while not resolved and waited < 15 do
						task.wait(0.1)
						waited += 0.1
					end
					if not resolved then
						conn:Disconnect()
						reject("Timed out waiting for sync: " .. event .. ":" .. key)
						return
					end
				end

				id = _resolveId(event, key)
			end

			local ok, res = pcall(_invokeRemote.InvokeServer, _invokeRemote, id, data)
			if ok then
				resolve(res)
			else
				reject(res)
			end
		end):catch(function(err)
			Logger:ErrorLog("InvokeServer:" .. key, err)
			return Promise.reject(err)
		end)
	end
end

--|| SELF-INITIALIZE ON REQUIRE
Local._initialize()

return Shared
