-- Drives the repeating airplane cycle for the InProgress state:
-- Arrived -> Boarding -> Departing -> Waiting -> loop. Purely attribute-driven
-- (Workspace.GateStage/GateTimeLeft/BoardingOpen), no Network remotes, so any
-- system can react without this service knowing about them.
--|| Services
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local RoundService = require(script.Parent.RoundService)
local MapService = require(script.Parent.MapService)

--|| Types
export type GateStage = "Arrived" | "Boarding" | "Departing" | "Waiting"

--|| Variables
local _connections: {RBXScriptConnection} = {}
local _cycleId = 0

local _doorAnimator: Animator? = nil
local _doorTracks: {[string]: AnimationTrack} = {}
local _doorMarkerConnections: {RBXScriptConnection} = {}

local isStudio = RunService:IsStudio()

--|| Constants
local ARRIVED_DURATION = isStudio and 10 or 15 -- plane taxis in, gate still closed
local BOARDING_DURATION = isStudio and 15 or 45 -- gate open — BoardingOpen=true
local DEPARTING_DURATION = isStudio and 10 or 15 -- gate just closed, plane taxis out
local WAITING_DURATION = isStudio and 10 or 15 -- empty gate, next plane inbound

local ATTR_STAGE = "GateStage"
local ATTR_TIME_LEFT = "GateTimeLeft"
local ATTR_BOARDING_OPEN = "BoardingOpen"

-- [[ Departing Door animation ]] --
-- Two looped Idle tracks (door held open/closed) and two one-shot Action
-- tracks (the swing), which hand off to the matching Idle via animation-event
-- markers (Open/Close) rather than the Action track's Stopped event, since
-- the Action clip keeps playing a short settle after the marker.
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
	Workspace:SetAttribute(ATTR_BOARDING_OPEN, stage == "Boarding")

	if stage == "Boarding" then
		Local.OpenDoor()
	elseif stage == "Departing" then
		Local.CloseDoor()
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
end

function Local.SetupDoor()
	Local.TeardownDoor()

	local activeMap = MapService.GetActiveMap()
	if not activeMap then
		warn("[GateService] SetupDoor called but MapService.GetActiveMap() returned nil — door will not animate")
		return
	end

	local assets = activeMap:FindFirstChild("Assets")
	if not assets then
		warn(`[GateService] {activeMap:GetFullName()} has no "Assets" folder — door will not animate`)
		return
	end

	local doorModel = assets:FindFirstChild(DOOR_ASSET_NAME)
	if not doorModel then
		local childNames = {}
		for _, child in assets:GetChildren() do
			table.insert(childNames, child.Name)
		end
		warn(`[GateService] "{DOOR_ASSET_NAME}" not found under {assets:GetFullName()} — door will not animate. Assets contains: {table.concat(childNames, ", ")}`)
		return
	end

	local controller = doorModel:FindFirstChildOfClass("AnimationController")
	if not controller then
		warn(`[GateService] {doorModel:GetFullName()} has no AnimationController — door will not animate`)
		return
	end

	local animator = controller:FindFirstChildOfClass("Animator")
	if not animator then
		warn(`[GateService] {controller:GetFullName()} has no Animator — door will not animate`)
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
		warn(`[GateService] openAction hit "{DOOR_OPEN_MARKER}" marker — swapping to openIdle`)
		Local.SwapDoorIdle("openIdle")
	end))

	table.insert(_doorMarkerConnections, _doorTracks.closeAction:GetMarkerReachedSignal(DOOR_CLOSE_MARKER):Connect(function()
		warn(`[GateService] closeAction hit "{DOOR_CLOSE_MARKER}" marker — swapping to closeIdle`)
		Local.SwapDoorIdle("closeIdle")
	end))

	-- The cycle always starts on "Arrived" (gate closed) — snap straight to
	-- the closed Idle rather than fading in from nothing.
	_doorTracks.closeIdle:Play(0)

	warn(`[GateService] door set up — model={doorModel:GetFullName()}, animator={animator:GetFullName()}, tracks loaded: openIdle, openAction, closeIdle, closeAction`)
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
		warn(`[GateService] SwapDoorIdle("{idleName}") — no such track loaded, doing nothing`)
		return
	end

	track:Play(DOOR_IDLE_FADE_TIME)
end

function Local.OpenDoor()
	if not _doorTracks.openAction then
		warn("[GateService] OpenDoor called but openAction track isn't loaded — SetupDoor never found the door, or hasn't run yet")
		return
	end

	warn("[GateService] OpenDoor — playing openAction")
	_doorTracks.closeAction:Stop(0)
	_doorTracks.openAction:Play()
end

function Local.CloseDoor()
	if not _doorTracks.closeAction then
		warn("[GateService] CloseDoor called but closeAction track isn't loaded — SetupDoor never found the door, or hasn't run yet")
		return
	end

	warn("[GateService] CloseDoor — playing closeAction")
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
