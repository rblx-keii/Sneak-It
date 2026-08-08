--|| Services
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

--|| Variables
local _networkConnections: {Network.Cleanup} = {}

--|| Constants
-- Tagged onto every crowd-seat's Seat instance by NpcService.Local.WatchSeats — reused as-is so
-- players sit in the exact same seats NPCs do (that's what lets a Smuggler blend in among them).
local PLAYER_SEAT_TAG = "PlayerSeat"
local MAX_SIT_DISTANCE = 10

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Seat", "Sit", function(player: Player, data: { seat: Seat }?)
		Local.TrySit(player, data and data.seat)
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.TrySit(player: Player, seat: Seat?)
	if typeof(seat) ~= "Instance" or not seat:IsA("Seat") then return end
	if not CollectionService:HasTag(seat, PLAYER_SEAT_TAG) then return end
	if seat.Occupant then return end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp or humanoid.Sit then return end

	if (hrp.Position - seat.Position).Magnitude > MAX_SIT_DISTANCE then return end

	seat:Sit(humanoid)
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared
