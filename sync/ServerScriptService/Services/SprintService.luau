--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local RoundService = require(script.Parent.RoundService)
local JailService = require(script.Parent.JailService)
local RagdollService = require(script.Parent.RagdollService)

--|| Types
type RoundState = RoundService.RoundState

--|| Variables
local _sprinting: { [Player]: number } = {}
local _connections: { RBXScriptConnection } = {}
local _networkConnections: { Network.Cleanup } = {}

--|| Constants
local SPRINT_WALKSPEED = 24

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Sprint", "Start", function(player: Player)
		Local.StartSprint(player)
	end))

	table.insert(_networkConnections, Network:BindEvent("Sprint", "Stop", function(player: Player)
		Local.StopSprint(player)
	end))

	RoundService.OnStateChange:Connect(function(newState: RoundState)
		if newState ~= "InProgress" then
			for player in _sprinting do
				Local.StopSprint(player)
			end
		end
	end)

	JailService.OnJailed:Connect(function(player: Player)
		Local.StopSprint(player)
	end)

	RagdollService.OnPlayerRagdolled:Connect(function(player: Player)
		Local.StopSprint(player)
	end)

	table.insert(_connections, Players.PlayerRemoving:Connect(function(player: Player)
		_sprinting[player] = nil
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.StartSprint(player: Player)
	if _sprinting[player] then return end
	if RoundService.GetState() ~= "InProgress" then return end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	_sprinting[player] = humanoid.WalkSpeed
	humanoid.WalkSpeed = SPRINT_WALKSPEED
end

function Local.StopSprint(player: Player)
	local originalWalkSpeed = _sprinting[player]
	if not originalWalkSpeed then return end
	_sprinting[player] = nil

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = originalWalkSpeed
	end
end

-- [[ Public Functions ]] --
function Shared.IsSprinting(player: Player): boolean
	return _sprinting[player] ~= nil
end

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared
