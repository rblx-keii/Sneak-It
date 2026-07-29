--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local JailService = require(script.Parent.JailService)
local TeamService = require(script.Parent.TeamService)
local DataService = require(script.Parent.DataService)
local RewardService = require(script.Parent.RewardService)

--|| Types
type DroppedItem = {
	part: BasePart,
	despawnThread: thread
}

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _droppedItems: {DroppedItem} = {}

--|| Constants
local ARREST_RANGE = 10
local ITEM_DESPAWN_TIME = 10
local ARREST_REWARD = 15

local RAYCAST_PARAMS = RaycastParams.new()

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude

	table.insert(_networkConnections, Network:BindEvent("Arrest", "Attempt", function(tsaPlayer: Player, data: { targetUserId: number?, npcId: string? })
		if data.npcId then
			local npcService = Local.GetNpcService()
			local npc = npcService and npcService.FindNPCById(data.npcId)
			if npc then
				Shared.AttemptArrestNPC(tsaPlayer, npc)
			end
			return
		end

		if data.targetUserId then
			local targetPlayer = Players:GetPlayerByUserId(data.targetUserId)
			if targetPlayer then
				Shared.AttemptArrest(tsaPlayer, targetPlayer)
			end
		end
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --

function Local.GetNpcService(): any
	local module = script.Parent:FindFirstChild("NpcService")
	if not module then return nil end

	local ok, service = pcall(require, module)
	if not ok then return nil end

	return service
end

function Local.GetTargetHRP(target: Player | Model): BasePart?
	if typeof(target) ~= "Instance" then return nil end

	if target:IsA("Player") then
		return target.Character and target.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	elseif target:IsA("Model") then
		return target:FindFirstChild("HumanoidRootPart") :: BasePart?
	end

	return nil
end

function Local.IsInArrestRange(tsaPlayer: Player, target: Player | Model): boolean
	local tsaHRP = Local.GetTargetHRP(tsaPlayer)
	local targetHRP = Local.GetTargetHRP(target)

	if not tsaHRP or not targetHRP then return false end

	local distance = (tsaHRP.Position - targetHRP.Position).Magnitude
	return distance <= ARREST_RANGE
end

function Local.HasLineOfSight(tsaPlayer: Player, target: Player | Model): boolean
	local tsaHRP = Local.GetTargetHRP(tsaPlayer)
	local targetHRP = Local.GetTargetHRP(target)

	if not tsaHRP or not targetHRP then return false end

	local targetInstance = (target:IsA("Player") and target.Character) or target
	RAYCAST_PARAMS.FilterDescendantsInstances = { tsaPlayer.Character, targetInstance }

	local origin = tsaHRP.Position
	local direction = targetHRP.Position - origin

	local result = Workspace:Raycast(origin, direction, RAYCAST_PARAMS)
	return result == nil
end

-- [[ Public Functions ]] --
function Shared.AttemptArrest(tsaPlayer: Player, targetPlayer: Player)
	if TeamService.GetTeam(tsaPlayer) ~= "TSA" then return end
	if TeamService.GetTeam(targetPlayer) ~= "Smuggler" then return end
	if JailService.IsJailed(tsaPlayer) then return end
	if JailService.IsJailed(targetPlayer) then return end
	if not Local.IsInArrestRange(tsaPlayer, targetPlayer) then return end
	if not Local.HasLineOfSight(tsaPlayer, targetPlayer) then return end

	JailService.JailPlayer(targetPlayer, "Arrested")

	RewardService.GrantTeamTaskReward(tsaPlayer, ARREST_REWARD)
	DataService.UpdateData(tsaPlayer, { type = "UpdateProfile", data = { key = "totalArrests", amount = 1 } })

	Network:FireClient("Arrest", tsaPlayer, "Success", { targetUserId = targetPlayer.UserId })
	Network:FireClient("Arrest", targetPlayer, "Caught", { arrestedBy = tsaPlayer.UserId })
end

function Shared.AttemptArrestNPC(tsaPlayer: Player, npc: Model)
	if TeamService.GetTeam(tsaPlayer) ~= "TSA" then return end
	if JailService.IsJailed(tsaPlayer) then return end
	if not Local.IsInArrestRange(tsaPlayer, npc) then return end
	if not Local.HasLineOfSight(tsaPlayer, npc) then return end

	local npcService = Local.GetNpcService()
	if not npcService or not npcService.IsNPC(npc) then return end

	local kind = npcService.GetNPCKind(npc)

	if kind == "Decoy" then
		npcService.CaptureDecoy(npc)
		Network:FireClient("Arrest", tsaPlayer, "Success", { npcId = npc:GetAttribute("UID") })
	else
		Shared.RegisterFalseArrest(tsaPlayer)
	end
end

function Shared.RegisterFalseArrest(tsaPlayer: Player)
	JailService.JailPlayer(tsaPlayer, "Strike")
end

return Shared