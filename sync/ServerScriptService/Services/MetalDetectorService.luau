--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local ZonePlus = require(ReplicatedStorage.Modules.Libs.ZonePlus)
local Network = require(ReplicatedStorage.Modules.Network)

local RoundService = require(script.Parent.RoundService)
local TeamService = require(script.Parent.TeamService)

--|| Variables
local _zones: {[BasePart]: ZonePlus.ZoneType} = {}
local _connections: {RBXScriptConnection} = {}
local _alarmCooldowns: {[Player]: number} = {}

local Local = {}
local Shared = {}

--|| Constants
local METAL_DETECTOR_TAG = "MetalDetector"
local IGNORE_ALARM_ATTR = "IgnoreAlarm"
local ALARM_COOLDOWN = 5

local FLASH_COLOR = Color3.fromRGB(220, 50, 50)
local FLASH_RESET_DELAY = 1.5

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	for _, part in CollectionService:GetTagged(METAL_DETECTOR_TAG) do
		Local.SetupZone(part)
	end

	table.insert(_connections, CollectionService:GetInstanceAddedSignal(METAL_DETECTOR_TAG):Connect(Local.SetupZone))
	table.insert(_connections, CollectionService:GetInstanceRemovedSignal(METAL_DETECTOR_TAG):Connect(Local.RemoveZone))

	table.insert(_connections, Players.PlayerRemoving:Connect(function(player: Player)
		_alarmCooldowns[player] = nil
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetupZone(part: Instance)
	if not part:IsA("BasePart") then return end
	if _zones[part] then return end

	local zone = ZonePlus.new(part)
	zone:relocate()

	zone.playerEntered:Connect(function(player: Player)
		Local.OnPlayerEntered(player, part)
	end)

	_zones[part] = zone
end

function Local.RemoveZone(part: BasePart)
	local zone = _zones[part]
	if zone then
		zone:destroy()
		_zones[part] = nil
	end
end

function Local.IsOnCooldown(player: Player): boolean
	local cooldownUntil = _alarmCooldowns[player]
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

function Local.BroadcastAlarm(offendingPlayer: Player, position: Vector3)
	for _, tsaPlayer in Players:GetPlayers() do
		if tsaPlayer.Team and tsaPlayer.Team.Name == "TSA" then
			Network:FireClient("Checkpoint", tsaPlayer, "Alarm", {
				playerId = offendingPlayer.UserId,
				position = position,
			})
		end
	end
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

	Local.BroadcastAlarm(player, position)
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
