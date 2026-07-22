--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local ItemService = require(script.Parent.ItemService)
local JailService = require(script.Parent.JailService)
local RagdollService = require(script.Parent.RagdollService)

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _lifecycleConnections: {RBXScriptConnection} = {}

local Local = {}
local Shared = {}

Local.activeSessions = {} :: { [number]: StealSession } -- keyed by player.UserId
Local.lockedNPCs = {} :: { [Model]: StealSession }
Local.retryCooldowns = {} :: { [Model]: number }

--|| Types
type StealSession = {
	player: Player,
	npc: Model,
	threshold: number,
	startTime: number,
	active: boolean,
}

--|| Constants
local MAX_STEAL_DISTANCE = 8
local DEFAULT_STEAL_THRESHOLD = 3 -- seconds, used if the NPC has no StealThreshold attribute
local COMPLETION_TOLERANCE = 0.5 -- seconds of slack allowed for network latency when validating a Complete
local TIMEOUT_BUFFER = 1.5 -- seconds past threshold before an unfinished session auto-fails
local WATCH_TICK_RATE = 0.25
local RETRY_COOLDOWN = 5 -- seconds before the same NPC can be targeted again after a result

local NPC_FOLDER_NAME = "NPCs"

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Steal", "Start", function(player: Player, data: { npcId: string })
		local npc = Local.FindNPCById(data and data.npcId)
		if npc then
			Shared.StartSteal(player, npc)
		end
	end))

	table.insert(_networkConnections, Network:BindEvent("Steal", "Complete", function(player: Player, data: { npcId: string })
		local npc = Local.FindNPCById(data and data.npcId)
		if npc then
			Shared.CompleteSteal(player, npc)
		end
	end))

	table.insert(_lifecycleConnections, JailService.OnJailed:Connect(function(player: Player)
		Shared.CancelSteal(player, "Jailed")
	end))

	table.insert(_lifecycleConnections, RagdollService.OnPlayerRagdolled:Connect(function(player: Player)
		Shared.CancelSteal(player, "Ragdolled")
	end))

	table.insert(_lifecycleConnections, Players.PlayerRemoving:Connect(function(player: Player)
		Shared.CancelSteal(player, "Disconnected")
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.FindNPCById(npcId: string?): Model?
	if not npcId or npcId == "" then return nil end

	local npcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	if not npcFolder then return nil end

	for _, npc in npcFolder:GetChildren() do
		if npc:IsA("Model") and npc:GetAttribute("UID") == npcId then
			return npc
		end
	end

	return nil
end

function Local.GetDistance(player: Player, npc: Model): number?
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local npcHrp = npc:FindFirstChild("HumanoidRootPart") :: BasePart?

	if not hrp or not npcHrp then return nil end

	return (hrp.Position - npcHrp.Position).Magnitude
end

function Local.BroadcastAlert(npc: Model, kind: "Caught" | "Stolen")
	local npcServiceModule = script.Parent:FindFirstChild("NpcService")
	if npcServiceModule then
		local ok, npcService = pcall(require, npcServiceModule)
		if ok and npcService.ForceAlert then
			npcService.ForceAlert(npc)
		end
	end

	local anchor = npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	local position = anchor and anchor.Position or npc:GetPivot().Position

	for _, securityPlayer in Players:GetPlayers() do
		if securityPlayer:GetAttribute("Team") == "Security" then
			Network:FireClient("Steal", securityPlayer, "Alarm", {
				npcId = npc:GetAttribute("UID") or npc.Name,
				position = position,
				kind = kind,
			})
		end
	end
end

function Local.SetRetryCooldown(npc: Model)
	Local.retryCooldowns[npc] = workspace:GetServerTimeNow() + RETRY_COOLDOWN
end

function Local.EndSession(session: StealSession)
	session.active = false
	Local.lockedNPCs[session.npc] = nil

	if Local.activeSessions[session.player.UserId] == session then
		Local.activeSessions[session.player.UserId] = nil
	end
end

function Local.TriggerSuccess(session: StealSession)
	Local.EndSession(session)

	local originCFrame = session.npc:GetPivot()
	local droppedBag = ItemService.ForceDropItem(session.npc)

	if droppedBag then
		ItemService.PickupItem(session.player, droppedBag, originCFrame)
	end

	Network:FireClient("Steal", session.player, "Result", { result = "Success" })
	Local.BroadcastAlert(session.npc, "Stolen")
	Local.SetRetryCooldown(session.npc)
end

function Local.TriggerFailure(session: StealSession, reason: string)
	Local.EndSession(session)

	Network:FireClient("Steal", session.player, "Result", { result = "Failure", reason = reason })
	Local.BroadcastAlert(session.npc, "Caught")
	Local.SetRetryCooldown(session.npc)
end

function Local.RunSessionWatch(session: StealSession)
	local deadline = session.startTime + session.threshold + TIMEOUT_BUFFER

	while session.active do
		task.wait(WATCH_TICK_RATE)
		if not session.active then return end

		local npc = session.npc
		if not npc or not npc.Parent then
			Local.TriggerFailure(session, "TargetLost")
			return
		end

		local distance = Local.GetDistance(session.player, npc)
		if not distance then
			Local.TriggerFailure(session, "Invalid")
			return
		end

		if distance > MAX_STEAL_DISTANCE then
			Local.TriggerFailure(session, "OutOfRange")
			return
		end

		if workspace:GetServerTimeNow() >= deadline then
			Local.TriggerFailure(session, "Timeout")
			return
		end
	end
end

-- [[ Public Functions ]] --
function Shared.StartSteal(player: Player, npcModel: Model): boolean
	if not npcModel or not npcModel.Parent then return false end

	if ItemService.IsHoldingBag()(player) then return false end
	if Local.activeSessions[player.UserId] then return false end
	if Local.lockedNPCs[npcModel] then return false end

	local cooldownUntil = Local.retryCooldowns[npcModel]
	if cooldownUntil and workspace:GetServerTimeNow() < cooldownUntil then return false end

	local npcHeldItemName = npcModel:GetAttribute("HeldItem")
	if not npcHeldItemName or npcHeldItemName == "" then return false end

	local heldModel = npcModel:FindFirstChild(npcHeldItemName)
	if not heldModel or not heldModel:GetAttribute("IsBag") then return false end

	local distance = Local.GetDistance(player, npcModel)
	if not distance or distance > MAX_STEAL_DISTANCE then return false end

	local threshold = npcModel:GetAttribute("StealThreshold")
	if type(threshold) ~= "number" or threshold <= 0 then
		threshold = DEFAULT_STEAL_THRESHOLD
	end

	local session: StealSession = {
		player = player,
		npc = npcModel,
		threshold = threshold,
		startTime = workspace:GetServerTimeNow(),
		active = true,
	}

	Local.activeSessions[player.UserId] = session
	Local.lockedNPCs[npcModel] = session

	task.spawn(Local.RunSessionWatch, session)

	return true
end

function Shared.CompleteSteal(player: Player, npcModel: Model): boolean
	local session = Local.activeSessions[player.UserId]
	if not session or not session.active then return false end
	if session.npc ~= npcModel then return false end

	local elapsed = workspace:GetServerTimeNow() - session.startTime
	if elapsed + COMPLETION_TOLERANCE < session.threshold then
		return false
	end

	local distance = Local.GetDistance(player, npcModel)
	if not distance or distance > MAX_STEAL_DISTANCE then
		Local.TriggerFailure(session, "OutOfRange")
		return false
	end

	Local.TriggerSuccess(session)
	return true
end

function Shared.CancelSteal(player: Player, reason: string?)
	local session = Local.activeSessions[player.UserId]
	if not session then return end

	Local.TriggerFailure(session, reason or "Cancelled")
end

function Shared.GetActiveSession(player: Player): StealSession?
	return Local.activeSessions[player.UserId]
end

function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	for _, conn in _lifecycleConnections do
		conn:Disconnect()
	end
	table.clear(_lifecycleConnections)

	table.clear(Local.activeSessions)
	table.clear(Local.lockedNPCs)
	table.clear(Local.retryCooldowns)
end

return Shared