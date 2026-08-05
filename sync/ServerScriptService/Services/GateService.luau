--|| Services
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local RoundService = require(script.Parent.RoundService)
local MapService = require(script.Parent.MapService)
local NodeGraph = require(script.Parent.NpcService.NodeGraph)

--|| Types
export type GateStage = "Arrived" | "Boarding" | "Departing" | "Waiting"

--|| Variables
local _connections: {RBXScriptConnection} = {}
local _cycleId = 0

local _doorModel: Model? = nil
local _doorAnimator: Animator? = nil
local _doorTracks: {[string]: AnimationTrack} = {}
local _doorMarkerConnections: {RBXScriptConnection} = {}

local isStudio = RunService:IsStudio()

--|| Constants
local ARRIVED_DURATION = isStudio and 10 or 15
local BOARDING_DURATION = isStudio and 15 or 45
local DEPARTING_DURATION = isStudio and 10 or 15
local WAITING_DURATION = isStudio and 10 or 15

local ATTR_STAGE = "GateStage"
local ATTR_TIME_LEFT = "GateTimeLeft"
local ATTR_BOARDING_OPEN = "BoardingOpen"

local DOOR_ASSET_NAME = "DepartingDoor"
local DOOR_ANIM_IDS = {
	openIdle = 72890270209807,
	openAction = 91958905511553,
	closeIdle = 123729146535570,
	closeAction = 83136433273582,
}
local DOOR_OPEN_MARKER = "Open"
local DOOR_CLOSE_MARKER = "Close"
local DOOR_IDLE_FADE_TIME = 0.15
local DOOR_COLLISION_GROUP_OPEN = "DoorOpen"
local DOOR_COLLISION_GROUP_CLOSED = "Default"

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, RoundService.OnStateChange:Connect(Local.OnRoundStateChange))

	if RoundService.GetState() == "InProgress" then
		Local.OnRoundStateChange("InProgress")
	end
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.OnRoundStateChange(newState: string)
	if newState == "InProgress" then
		Local.StartCycle()
	else
		Local.StopCycle()
	end
end

function Local.SetStage(stage: GateStage)
	Workspace:SetAttribute(ATTR_STAGE, stage)

	if stage == "Boarding" then
		Local.OpenDoor()
	else
		Workspace:SetAttribute(ATTR_BOARDING_OPEN, false)
		if stage == "Departing" then
			Local.CloseDoor()
		end
	end
end

-- [[ Departing Door ]] --
function Local.TeardownDoor()
	for _, conn in _doorMarkerConnections do
		conn:Disconnect()
	end
	table.clear(_doorMarkerConnections)

	for _, track in _doorTracks do
		track:Stop(0)
		track:Destroy()
	end
	table.clear(_doorTracks)

	_doorAnimator = nil
	_doorModel = nil
end

function Local.SetDoorCollisionGroup(groupName: string)
	if not _doorModel then return end
	for _, descendant in _doorModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end

	NodeGraph.InvalidateLoSCache()
end

function Local.SetupDoor()
	Local.TeardownDoor()

	local activeMap = MapService.GetActiveMap()
	if not activeMap then
		return
	end

	local assets = activeMap:FindFirstChild("Assets")
	if not assets then
		return
	end

	local doorModel = assets:FindFirstChild(DOOR_ASSET_NAME)
	if not doorModel then
		local childNames = {}
		for _, child in assets:GetChildren() do
			table.insert(childNames, child.Name)
		end
		return
	end
	_doorModel = doorModel :: Model

	local controller = doorModel:FindFirstChildOfClass("AnimationController")
	if not controller then
		return
	end

	local animator = controller:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	_doorAnimator = animator

	for name, assetId in DOOR_ANIM_IDS do
		local animation = Instance.new("Animation")
		animation.AnimationId = `rbxassetid://{assetId}`

		local track = animator:LoadAnimation(animation)
		track.Priority = if name == "openIdle" or name == "closeIdle" then Enum.AnimationPriority.Idle else Enum.AnimationPriority.Action
		track.Looped = name == "openIdle" or name == "closeIdle"

		_doorTracks[name] = track
	end

	table.insert(_doorMarkerConnections, _doorTracks.openAction:GetMarkerReachedSignal(DOOR_OPEN_MARKER):Connect(function()
		Local.SwapDoorIdle("openIdle")
		Local.SetDoorCollisionGroup(DOOR_COLLISION_GROUP_OPEN)

		if Workspace:GetAttribute(ATTR_STAGE) == "Boarding" then
			Workspace:SetAttribute(ATTR_BOARDING_OPEN, true)
		end
	end))

	table.insert(_doorMarkerConnections, _doorTracks.closeAction:GetMarkerReachedSignal(DOOR_CLOSE_MARKER):Connect(function()
		Local.SwapDoorIdle("closeIdle")
		Local.SetDoorCollisionGroup(DOOR_COLLISION_GROUP_CLOSED)
	end))

	_doorTracks.closeIdle:Play(0)
	Local.SetDoorCollisionGroup(DOOR_COLLISION_GROUP_CLOSED)

end

function Local.SwapDoorIdle(idleName: string)
	if _doorTracks.openIdle and _doorTracks.openIdle.IsPlaying then
		_doorTracks.openIdle:Stop(DOOR_IDLE_FADE_TIME)
	end
	if _doorTracks.closeIdle and _doorTracks.closeIdle.IsPlaying then
		_doorTracks.closeIdle:Stop(DOOR_IDLE_FADE_TIME)
	end

	local track = _doorTracks[idleName]
	if not track then
		return
	end

	track:Play(DOOR_IDLE_FADE_TIME)
end

function Local.OpenDoor()
	if not _doorTracks.openAction then
		return
	end

	_doorTracks.closeAction:Stop(0)
	_doorTracks.openAction:Play()
end

function Local.CloseDoor()
	if not _doorTracks.closeAction then
		return
	end

	_doorTracks.openAction:Stop(0)
	_doorTracks.closeAction:Play()
end

function Local.RunStage(cid: number, stage: GateStage, duration: number): boolean
	Local.SetStage(stage)

	for i = duration, 0, -1 do
		if _cycleId ~= cid then return false end
		if RoundService.GetState() ~= "InProgress" then return false end

		Workspace:SetAttribute(ATTR_TIME_LEFT, i)
		task.wait(1)
	end

	return _cycleId == cid
end

function Local.StartCycle()
	_cycleId += 1
	local cid = _cycleId

	Local.SetupDoor()

	task.spawn(function()
		while _cycleId == cid and RoundService.GetState() == "InProgress" do
			if not Local.RunStage(cid, "Arrived", ARRIVED_DURATION) then break end
			if not Local.RunStage(cid, "Boarding", BOARDING_DURATION) then break end
			if not Local.RunStage(cid, "Departing", DEPARTING_DURATION) then break end
			if not Local.RunStage(cid, "Waiting", WAITING_DURATION) then break end
		end
	end)
end

function Local.StopCycle()
	_cycleId += 1

	Workspace:SetAttribute(ATTR_STAGE, nil)
	Workspace:SetAttribute(ATTR_TIME_LEFT, nil)
	Workspace:SetAttribute(ATTR_BOARDING_OPEN, false)

	Local.TeardownDoor()
end

-- [[ Public Functions ]] --
function Shared.GetStage(): GateStage?
	return Workspace:GetAttribute(ATTR_STAGE)
end

function Shared.IsBoardingOpen(): boolean
	return Workspace:GetAttribute(ATTR_BOARDING_OPEN) == true
end

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	Local.StopCycle()
end

return Shared
