--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--|| References
local ZonePlus = require(ReplicatedStorage.Modules.Libs.ZonePlus)
local Network = require(ReplicatedStorage.Modules.Network)

local RoundService = require(script.Parent.RoundService)
local TeamService = require(script.Parent.TeamService)
local ItemService = require(script.Parent.ItemService)

--|| Variables
local _zones: {[BasePart]: ZonePlus.ZoneType} = {}
local _connections: {RBXScriptConnection} = {}
local _alarmCooldowns: {[Instance]: number} = {}

local Local = {}
local Shared = {}

--|| Constants
local METAL_DETECTOR_TAG = "XRAY-MetalDetector"
local NPC_FOLDER_NAME = "NPCs"
local IGNORE_ALARM_ATTR = "IgnoreAlarm"
local ALARM_COOLDOWN = 5
local ALARM_MESSAGE = "Suspected Smuggler has breached into the Platform Zone"
local HIGHLIGHT_DURATION = 4 -- seconds the offender stays highlighted on TSA clients (see HighlightController)

local FLASH_COLOR = Color3.fromRGB(220, 50, 50)
local FLASH_RESET_DELAY = 1.5

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, CollectionService:GetInstanceAddedSignal(METAL_DETECTOR_TAG):Connect(Local.SetupZone))
	table.insert(_connections, CollectionService:GetInstanceRemovedSignal(METAL_DETECTOR_TAG):Connect(Local.RemoveZone))

	table.insert(_connections, Players.PlayerRemoving:Connect(function(player: Player)
		_alarmCooldowns[player] = nil
	end))

	Local.WatchNpcFolder()

	-- The very first ZonePlus.new() call anywhere in the game lazily builds ZoneController's global
	-- player-tracking singleton, which synchronously does character:WaitForChild("Humanoid", 3) per
	-- already-connected player — multiple seconds of blocking buried inside the vendored library.
	-- Deferred so it can't stall the Loader's sequential server Init chain (this service doesn't need
	-- to be armed before the rest of the server finishes booting).
	task.spawn(function()
		for _, part in CollectionService:GetTagged(METAL_DETECTOR_TAG) do
			Local.SetupZone(part)
		end
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
-- Crowd NPCs aren't Players, so ZonePlus's playerEntered never sees them — they have to be registered
-- individually via trackItem/itemEntered instead (see Local.TrackNpc), same as real Smugglers, so
-- which characters can trip the detector doesn't itself give away who's actually a Smuggler.
--
-- NpcService only creates Workspace.NPCs once a round reaches "Starting" (and destroys/recreates it
-- every round after) — it doesn't exist yet at server boot, so this must not block waiting for it.
function Local.WatchNpcFolder()
	local existing = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	if existing then
		Local.SetupNpcFolder(existing)
	end

	table.insert(_connections, Workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == NPC_FOLDER_NAME then
			Local.SetupNpcFolder(child)
		end
	end))
end

function Local.SetupNpcFolder(npcFolder: Instance)
	for _, npc in npcFolder:GetChildren() do
		Local.TrackNpc(npc)
	end

	table.insert(_connections, npcFolder.ChildAdded:Connect(Local.TrackNpc))
end

function Local.TrackNpc(npc: Instance)
	if not npc:IsA("Model") then return end
	for _, zone in _zones do
		zone:trackItem(npc)
	end
end

function Local.SetupZone(part: Instance)
	if not part:IsA("BasePart") then return end
	if _zones[part] then return end

	local zone = ZonePlus.new(part)
	zone:relocate()

	zone.playerEntered:Connect(function(player: Player)
		Local.OnPlayerEntered(player, part)
	end)

	zone.itemEntered:Connect(function(item: Instance)
		Local.OnNpcEntered(item, part)
	end)

	_zones[part] = zone

	local npcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	if npcFolder then
		for _, npc in npcFolder:GetChildren() do
			zone:trackItem(npc)
		end
	end
end

function Local.RemoveZone(part: BasePart)
	local zone = _zones[part]
	if zone then
		zone:destroy()
		_zones[part] = nil
	end
end

function Local.IsOnCooldown(entity: Instance): boolean
	local cooldownUntil = _alarmCooldowns[entity]
	return cooldownUntil ~= nil and workspace:GetServerTimeNow() < cooldownUntil
end

function Local.FlashDetector(part: BasePart)
	local originalColor = part:GetAttribute("OriginalColor")
	if typeof(originalColor) ~= "Color3" then
		originalColor = part.Color
		part:SetAttribute("OriginalColor", originalColor)
	end

	part.Color = FLASH_COLOR

	task.delay(FLASH_RESET_DELAY, function()
		if part and part.Parent then
			part.Color = originalColor
		end
	end)
end

function Local.GetTsaPlayers(): {Player}
	local tsaPlayers = {}
	for _, player in Players:GetPlayers() do
		if player.Team and player.Team.Name == "TSA" then
			table.insert(tsaPlayers, player)
		end
	end
	return tsaPlayers
end

function Local.BroadcastAlarm(targetCharacter: Model, position: Vector3)
	for _, tsaPlayer in Local.GetTsaPlayers() do
		Network:FireClient("Checkpoint", tsaPlayer, "Alarm", {
			position = position,
			message = ALARM_MESSAGE,
		})
		Network:FireClient("Highlight", tsaPlayer, "Start", { targetCharacter = targetCharacter })
	end

	task.delay(HIGHLIGHT_DURATION, function()
		for _, tsaPlayer in Local.GetTsaPlayers() do
			Network:FireClient("Highlight", tsaPlayer, "Stop", { targetCharacter = targetCharacter })
		end
	end)
end

function Local.OnPlayerEntered(player: Player, part: BasePart)
	if RoundService.GetState() ~= "InProgress" then return end
	if TeamService.GetTeam(player) ~= "Smuggler" then return end

	local character = player.Character
	if not character then return end

	if character:GetAttribute(IGNORE_ALARM_ATTR) then return end

	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return end

	if Local.IsOnCooldown(player) then return end
	_alarmCooldowns[player] = workspace:GetServerTimeNow() + ALARM_COOLDOWN

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local position = hrp and hrp.Position or part.Position

	Local.BroadcastAlarm(character, position)
	Local.FlashDetector(part)
end

-- Unlike players (who trigger on any held item — see Project.md's design), most crowd NPCs are
-- carrying a plain DuffleBag just for ambience (BAG_SPAWN_CHANCE), so gating NPCs on "any item" would
-- alarm on nearly every NPC that walks through. Gated on actual contraband instead, matching what a
-- real detector would flag.
function Local.OnNpcEntered(npc: Instance, part: BasePart)
	if not npc:IsA("Model") then return end
	if RoundService.GetState() ~= "InProgress" then return end
	if npc:GetAttribute(IGNORE_ALARM_ATTR) then return end

	local heldItemName = npc:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return end

	local heldItem = npc:FindFirstChild(heldItemName)
	if not heldItem or not heldItem:IsA("Model") then return end
	if ItemService.GetContrabandItemCount(heldItem) <= 0 then return end

	if Local.IsOnCooldown(npc) then return end
	_alarmCooldowns[npc] = workspace:GetServerTimeNow() + ALARM_COOLDOWN

	local hrp = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	local position = hrp and hrp.Position or part.Position

	Local.BroadcastAlarm(npc, position)
	Local.FlashDetector(part)
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	for _, zone in _zones do
		zone:destroy()
	end
	table.clear(_zones)

	table.clear(_alarmCooldowns)
end

return Shared
