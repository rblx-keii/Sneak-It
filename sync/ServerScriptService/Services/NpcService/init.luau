--|| Services
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)
local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)
local CharacterController = require(ReplicatedStorage.Modules.Shared.CharacterController)
local NodeGraph = require(script.NodeGraph)
local Queueing = require(script.Behaviors.Queueing)

local RoundService = require(script.Parent.RoundService)
local MapService = require(script.Parent.MapService)
local ItemService = require(script.Parent.ItemService)
local RagdollService = require(script.Parent.RagdollService)

--|| Types

export type NPCKind = "Crowd"

type Prefetch = {
	forNode: BasePart,
	awaitingDecision: boolean,
	nextNode: BasePart?,
	state: string?,
	waypoints: { PathWaypoint }?,
	path: Path?,
	moveTargetPos: Vector3?,
	alreadyThere: boolean,
	ready: boolean,
}

type BeltBagInfo = {
	npcUID: string,
	conveyorNode: BasePart,
	startPos: Vector3,
	endPos: Vector3,
	startTime: number,
	travelTime: number,
	arrived: boolean,
	indicatorFlashed: boolean,
}

type NPCRecord = {
	model: Model,
	actor: Actor,
	uid: string,
	humanoid: Humanoid,
	hrp: BasePart,
	currentNode: BasePart?,
	lastNode: BasePart?,
	targetNode: BasePart?,
	moveTargetPos: Vector3?,
	waypoints: { PathWaypoint }?,
	waypointIndex: number?,
	moveStartedAt: number,
	legExpectedDuration: number,
	lastProgressPos: Vector3,
	lastProgressCheckAt: number,
	stuckNudgeAttempts: number,
	lastBackSideNudgeAt: number,
	arrivedViaLink: boolean,
	awaitingDecision: boolean,
	decisionRequestedAt: number,
	lastRestTime: number,
	seatedAt: number,
	seatObject: Seat?,
	lineDwellUntil: number,
	departArrivedAt: number,
	wanderDwellUntil: number,
	willBoard: boolean?,
	busy: boolean,
	pathBlockedConn: RBXScriptConnection?,
	waypointMarkers: { BasePart }?,
	prefetch: Prefetch?,
	pendingBagNode: BasePart?,
	itemAnimTrack: AnimationTrack?,
	baseAnimTracks: CharacterController.AnimationSet?,
	unseating: boolean,
	reactionState: "None" | "Alert" | "Panicking",
	reactionEpoch: number,
	baseWalkSpeed: number,
	sprinting: boolean,
}

--|| Variables
local _connections: { RBXScriptConnection } = {}
local _npcConnections: { [Model]: { RBXScriptConnection } } = {}
local _activeNPCs: { NPCRecord } = {}
local _npcsFolder: Folder? = nil
local _nodesFolder: Instance? = nil
local _nextUid = 0
local _debugMarkersFolder: Folder? = nil
local _beltBags: { [Model]: BeltBagInfo } = {}
local _seatWatchConnections: { RBXScriptConnection } = {}

local Local = {}
local Shared = {}

Local.decisionReportEvent = Instance.new("BindableEvent")

--|| Constants
local NPC_FOLDER_NAME = "NPCs"
local DEBUG_MARKERS_FOLDER_NAME = "NPCDebugMarkers"
local STEALABLE_NPC_TAG = "StealableNPC"

-- Matches ScannerWand's green/red scan-result colors, so every TSA scan surface reads consistently.
local INDICATOR_CLEAN_COLOR = Color3.fromRGB(60, 220, 90)
local INDICATOR_CONTRABAND_COLOR = Color3.fromRGB(220, 50, 50)
local INDICATOR_RESET_DELAY = 2

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAYCAST_PARAMS.CollisionGroup = "NPC"

local SPAWN_RAYCAST_TOP_BUFFER = 10 -- studs above the Spawns.NPC part's top the floor raycast starts from
local SPAWN_RAYCAST_MAX_DISTANCE = 200
local SPAWN_FALLBACK_HIP_HEIGHT = 2 -- used only if the rig's own Humanoid.HipHeight reads 0

local PATH_AGENT_PARAMS = {
	AgentRadius = NPCConfig.PATH_AGENT_RADIUS,
	AgentHeight = NPCConfig.PATH_AGENT_HEIGHT,
	AgentCanJump = NPCConfig.PATH_AGENT_CAN_JUMP,
	AgentCanClimb = NPCConfig.PATH_AGENT_CAN_CLIMB,
	WaypointSpacing = NPCConfig.PATH_WAYPOINT_SPACING,
}

-- Same agent, tighter WaypointSpacing — used instead of PATH_AGENT_PARAMS whenever origin/goal have a
-- real vertical gap (see Local.GetPathAgentParams), since PathfindingService's waypoint-merging can
-- otherwise span the full spacing straight through a step/ledge/stair riser it should route around.
local PATH_AGENT_PARAMS_STEEP = {
	AgentRadius = NPCConfig.PATH_AGENT_RADIUS,
	AgentHeight = NPCConfig.PATH_AGENT_HEIGHT,
	AgentCanJump = NPCConfig.PATH_AGENT_CAN_JUMP,
	AgentCanClimb = NPCConfig.PATH_AGENT_CAN_CLIMB,
	WaypointSpacing = NPCConfig.PATH_WAYPOINT_SPACING_STEEP,
}

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, RoundService.OnStateChange:Connect(Local.OnRoundStateChange))
	table.insert(_connections, Local.decisionReportEvent.Event:Connect(Local.OnDecisionReported))

	-- Violence witnessed (player-on-player, player-on-NPC, or NPC-on-NPC ragdoll) panics every NPC
	-- in blast radius, no line-of-sight required — matches the pre-node-graph legacy behavior.
	table.insert(_connections, RagdollService.OnRagdolled:Connect(function(rig: Model)
		Shared.ForcePanic(rig:GetPivot().Position, NPCConfig.PANIC_RADIUS, false)
	end))

	table.insert(
		_connections,
		RunService.Heartbeat:Connect(function(_dt: number)
			if RoundService.GetState() ~= "InProgress" then
				return
			end

			for _, record in _activeNPCs do
				if
					record.busy
					and record.awaitingDecision
					and os.clock() - record.decisionRequestedAt > NPCConfig.DECISION_TIMEOUT
				then
					record.awaitingDecision = false
					record.busy = false
				end

				if record.busy then
					continue
				end
				record.busy = true

				task.spawn(function()
					local ok, stillPending = pcall(Local.ProcessNPCTick, record)
					if not ok then
						Local.Warn(`[NpcService] NPC tick error for {record.uid}: {stillPending}`)
						record.busy = false
					elseif not stillPending then
						record.busy = false
					end
				end)
			end
		end)
	)

	table.insert(
		_connections,
		Workspace:GetAttributeChangedSignal("BoardingOpen"):Connect(function()
			if Workspace:GetAttribute("BoardingOpen") then
				return
			end
			if not _nodesFolder then
				return
			end

			for _, record in _activeNPCs do
				if not record.targetNode then
					continue
				end
				if NodeGraph.GetZone(record.targetNode, _nodesFolder :: Instance) ~= "Depart" then
					continue
				end
				if
					record.currentNode
					and NodeGraph.GetZone(record.currentNode, _nodesFolder :: Instance) == "Depart"
				then
					continue
				end

				Local.CancelDepartApproach(record)
			end
		end)
	)

	local currentState = RoundService.GetState()
	if currentState == "Starting" or currentState == "InProgress" then
		Local.OnRoundStateChange(currentState)
	end
end

function Shared.Start() end

function Local.ProcessNPCTick(record: NPCRecord): boolean?
	if not record.actor.Parent then
		return
	end

	-- Alert/Panicking own movement entirely via their own task.delay chains (EnterAlert/EnterPanic/
	-- PanicWander) — the normal node-graph tick is fully suspended until ResumeAfterReaction clears this.
	if record.reactionState ~= "None" then
		return
	end

	-- Covers the full Unseat sequence (standing up AND the WalkClearOfSeat step that follows it)
	-- so a real decision can't get requested mid-stand-up and race the seat-clearing walk.
	if record.unseating then
		return
	end

	if record.seatedAt == 0 and Local.IsSeated(record) then
		Local.Unseat(record)
		return
	end

	if record.targetNode then
		Local.CheckWaypointProgress(record)
		return
	end

	if record.awaitingDecision then
		return
	end

	if not record.currentNode then
		Local.SnapToNearestNode(record)
		return
	end

	if record.prefetch and record.prefetch.forNode == record.currentNode then
		if record.prefetch.ready then
			local prefetch = record.prefetch :: Prefetch
			record.prefetch = nil
			Local.ConsumePrefetch(record, prefetch)
		end
		return
	end

	if record.pendingBagNode and record.pendingBagNode == record.currentNode then
		return
	end

	if record.seatedAt > 0 and workspace:GetServerTimeNow() - record.seatedAt < NPCConfig.SEAT_REST_DURATION then
		return
	end

	if Queueing.IsDwelling(record.lineDwellUntil) then
		return
	end

	if
		record.departArrivedAt > 0
		and workspace:GetServerTimeNow() - record.departArrivedAt >= NPCConfig.BOARD_DWELL
	then
		task.defer(Local.CleanupNPC, record.model)
		Local.ScheduleRespawn()
		return
	end

	if record.wanderDwellUntil > 0 and workspace:GetServerTimeNow() >= record.wanderDwellUntil then
		record.wanderDwellUntil = 0
		if record.model:GetAttribute("BehaviorType") ~= "Linear" then
			record.model:SetAttribute("BehaviorType", "Linear")
		end
		record.model:SetAttribute("WanderConfineZone", nil)
	end

	Local.UpdateBoardingRoll(record)

	record.awaitingDecision = true
	record.decisionRequestedAt = os.clock()
	record.actor:SendMessage("Decide", {
		npc = record.model,
		nodesFolder = _nodesFolder,
		currentNode = record.currentNode,
		lastNode = record.lastNode,
		arrivedViaLink = record.arrivedViaLink,
		behaviorType = record.model:GetAttribute("BehaviorType") or "Linear",
		lastRestTime = record.lastRestTime,
		willBoard = record.willBoard,
		holdingBag = Local.IsHoldingBag(record),
		pendingBagNode = record.pendingBagNode,
		confineZone = Local.GetWanderConfineZone(record),
	})
	return true
end

function Local.UpdateBoardingRoll(record: NPCRecord)
	local gateStage = Workspace:GetAttribute("GateStage")
	local planeArrived = gateStage == "Arrived" or gateStage == "Boarding"

	if not planeArrived then
		record.willBoard = nil
		return
	end

	if record.willBoard == nil then
		record.willBoard = math.random() < NPCConfig.BOARD_ROLL_CHANCE
	end
end

function Local.IsHoldingBag(record: NPCRecord): boolean
	local heldItem = record.model:GetAttribute("HeldItem")
	return heldItem ~= nil and heldItem ~= ""
end

function Local.GetWanderConfineZone(record: NPCRecord): string?
	return record.model:GetAttribute("WanderConfineZone")
end

function Local.UpdateStealableTag(record: NPCRecord)
	local heldItemName = record.model:GetAttribute("HeldItem")
	local isStealable = false

	if heldItemName and heldItemName ~= "" then
		local heldModel = record.model:FindFirstChild(heldItemName)
		isStealable = heldModel ~= nil and heldModel:GetAttribute("IsBag") == true
	end

	if isStealable then
		CollectionService:AddTag(record.model, STEALABLE_NPC_TAG)
	else
		CollectionService:RemoveTag(record.model, STEALABLE_NPC_TAG)
	end
end

-- [[ Private Functions — Round lifecycle ]] --
function Local.OnRoundStateChange(newState: string)
	if newState == "Starting" then
		Local.SpawnRound()
	elseif newState == "Ended" or newState == "Intermission" then
		Local.DespawnAll()
	end
end

function Local.SpawnRound()
	Local.DespawnAll()

	_npcsFolder = Instance.new("Folder")
	_npcsFolder.Name = NPC_FOLDER_NAME
	_npcsFolder.Parent = Workspace

	local activeMap = MapService.GetActiveMap()
	if not activeMap then
		Local.Warn("[NpcService] No active map — cannot build node graph")
		return
	end

	local nodesFolder = activeMap:FindFirstChild("Nodes")
	if not nodesFolder then
		Local.Warn("[NpcService] Active map has no 'Nodes' Folder — NPCs will have nowhere to walk")
		return
	end
	_nodesFolder = nodesFolder
	Local.ResetLineSlots(nodesFolder)
	Local.WatchSeats(nodesFolder)

	local template = Local.GetRigTemplate()
	if not template then
		return
	end

	for _ = 1, NPCConfig.MAX_NPCS do
		Local.SpawnNPC(template)
	end
end

function Local.ResetLineSlots(nodesFolder: Instance)
	for _, node in NodeGraph.EnumerateAllNodes(nodesFolder) do
		if NodeGraph.GetNodeType(node) == "linenode" then
			node:SetAttribute("Occupied", false)
			if not NodeGraph.IsSlotNode(node) then
				node:SetAttribute("LineIsFull", false)
				node:SetAttribute("EnRouteCount", 0)
			end
		end
	end
end

function Local.WatchSeats(nodesFolder: Instance)
	for _, node in NodeGraph.EnumerateAllNodes(nodesFolder) do
		if NodeGraph.GetNodeType(node) ~= "seatnode" then
			continue
		end

		NodeGraph.ReleaseSeatReservation(node)
		NodeGraph.SyncSeatOccupiedAttribute(node)

		local seat = NodeGraph.GetSeatObject(node)
		if not seat then
			continue
		end

		table.insert(
			_seatWatchConnections,
			seat:GetPropertyChangedSignal("Occupant"):Connect(function()
				NodeGraph.SyncSeatOccupiedAttribute(node)
			end)
		)
	end
end

function Local.DespawnAll()
	for _, record in _activeNPCs do
		Local.CleanupNPC(record.model)
	end
	table.clear(_activeNPCs)
	table.clear(_npcConnections)
	_nodesFolder = nil

	for _, conn in _seatWatchConnections do
		conn:Disconnect()
	end
	table.clear(_seatWatchConnections)

	if _npcsFolder then
		_npcsFolder:Destroy()
		_npcsFolder = nil
	end

	if _debugMarkersFolder then
		_debugMarkersFolder:Destroy()
		_debugMarkersFolder = nil
	end
end

function Local.GetRigTemplate(): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local rig = assets and assets:FindFirstChild("Rig")
	if not rig or not rig:IsA("Model") then
		Local.Warn("[NpcService] ReplicatedStorage.Assets.Rig not found or not a Model")
		return nil
	end
	return rig
end

function Local.GetSpawnZone(): BasePart?
	local activeMap = MapService.GetActiveMap()
	if not activeMap then
		return nil
	end

	local spawnsFolder = activeMap:FindFirstChild("Spawns")
	if not spawnsFolder then
		return nil
	end

	local zone = spawnsFolder:FindFirstChild("NPC")
	return zone and zone:IsA("BasePart") and zone or nil
end

function Local.GetRandomPositionInPart(part: BasePart): Vector3
	local halfX = part.Size.X / 2
	local halfZ = part.Size.Z / 2

	local localX = math.random() * 2 * halfX - halfX
	local localZ = math.random() * 2 * halfZ - halfZ

	local worldOffset = part.CFrame:VectorToWorldSpace(Vector3.new(localX, 0, localZ))
	return part.Position + worldOffset
end

function Local.RaycastSpawnFloor(xzPosition: Vector3, zoneTop: number): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if _npcsFolder then { _npcsFolder } else {}

	local origin = Vector3.new(xzPosition.X, zoneTop + SPAWN_RAYCAST_TOP_BUFFER, xzPosition.Z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -SPAWN_RAYCAST_MAX_DISTANCE, 0), params)
	return result and result.Position or nil
end

-- Raycasts down to the actual floor instead of trusting the zone part's own center height, same convention SpawnService uses for players
function Local.GetSpawnCFrame(humanoid: Humanoid, hrp: BasePart): CFrame
	local zone = Local.GetSpawnZone()
	if not zone then
		Local.Warn("[NpcService] Active map has no Spawns.NPC part — spawning at the world origin")
		return CFrame.new()
	end

	local xz = Local.GetRandomPositionInPart(zone)
	local zoneTop = zone.Position.Y + zone.Size.Y / 2
	local floorPos = Local.RaycastSpawnFloor(xz, zoneTop)

	local hipHeight = humanoid.HipHeight
	if hipHeight == 0 then
		hipHeight = SPAWN_FALLBACK_HIP_HEIGHT
	end

	local groundY = if floorPos then floorPos.Y else zone.Position.Y
	local position = Vector3.new(xz.X, groundY + hipHeight + hrp.Size.Y / 2, xz.Z)

	return CFrame.new(position) * (zone.CFrame - zone.CFrame.Position)
end

function Local.GetActorScriptTemplate(): Script?
	local template = script:FindFirstChild("ActorScript")
	if not template or not template:IsA("Script") then
		Local.Warn("[NpcService] ActorScript template not found")
		return nil
	end
	return template :: Script
end

function Local.InjectActor(npc: Model): Actor
	local actor = Instance.new("Actor")
	actor.Name = "Brain"

	local reportEventValue = Instance.new("ObjectValue")
	reportEventValue.Name = "ReportEvent"
	reportEventValue.Value = Local.decisionReportEvent
	reportEventValue.Parent = actor

	local template = Local.GetActorScriptTemplate()
	if template then
		local aiScript = template:Clone()
		aiScript.Enabled = true
		aiScript.Parent = actor
	end

	actor.Parent = npc

	return actor
end

function Local.SpawnNPC(template: Model)
	if not _npcsFolder then
		return
	end

	local model = template:Clone()
	model.Name = "NPC"

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		Local.Warn("[NpcService] Rig template is missing a Humanoid/HumanoidRootPart")
		model:Destroy()
		return
	end

	model:PivotTo(Local.GetSpawnCFrame(humanoid, hrp))
	model.Parent = _npcsFolder

	local anchoredCount = 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			if part.Anchored then
				anchoredCount += 1
				part.Anchored = false
			end
			part:SetNetworkOwner(nil)
			part.CollisionGroup = "NPC"

			if part ~= hrp then
				part.CanCollide = false
			end
		end
	end

	local baseWalkSpeed = NPCConfig.WALK_SPEED + (math.random() * 2 - 1) * NPCConfig.WALK_SPEED_JITTER
	humanoid.WalkSpeed = baseWalkSpeed

	_nextUid += 1
	local uid = `NPC_{_nextUid}_{math.floor(workspace:GetServerTimeNow() * 1000)}`
	model:SetAttribute("UID", uid)
	model:SetAttribute("Kind", "Crowd")
	model:SetAttribute("BehaviorType", "Linear")

	-- Every crowd NPC gets the same "Arrestable" affordance as a real Smuggler (see ArrestService) so
	-- the Handcuffs prompt can't be used to spot Smugglers just by which characters show a prompt.
	CollectionService:AddTag(model, "Arrestable")

	local actor = Local.InjectActor(model)
	Local.Warn(
		`[NpcService] Spawned {uid} at {model:GetPivot().Position} (BehaviorType=Linear, Nodes={_nodesFolder and _nodesFolder:GetFullName() or "nil"}, unanchored {anchoredCount} part(s), PlatformStand={humanoid.PlatformStand}, Sit={humanoid.Sit}, state={humanoid:GetState().Name})`
	)

	local record: NPCRecord = {
		model = model,
		actor = actor,
		uid = uid,
		humanoid = humanoid,
		hrp = hrp,
		currentNode = nil,
		lastNode = nil,
		targetNode = nil,
		moveTargetPos = nil,
		waypoints = nil,
		waypointIndex = nil,
		moveStartedAt = 0,
		legExpectedDuration = 0,
		lastProgressPos = hrp.Position,
		lastProgressCheckAt = 0,
		stuckNudgeAttempts = 0,
		lastBackSideNudgeAt = 0,
		arrivedViaLink = false,
		awaitingDecision = false,
		decisionRequestedAt = 0,
		lastRestTime = 0,
		seatedAt = 0,
		seatObject = nil,
		lineDwellUntil = 0,
		departArrivedAt = 0,
		wanderDwellUntil = 0,
		willBoard = nil,
		busy = false,
		pathBlockedConn = nil,
		waypointMarkers = nil,
		prefetch = nil,
		pendingBagNode = nil,
		itemAnimTrack = nil,
		baseAnimTracks = CharacterController.Setup(humanoid),
		unseating = false,
		reactionState = "None",
		reactionEpoch = 0,
		baseWalkSpeed = baseWalkSpeed,
		sprinting = false,
	}

	task.spawn(function()
		RunService.Heartbeat:Wait()
		Local.EquipStarterItem(record)
	end)

	local connections: { RBXScriptConnection } = {}
	table.insert(
		connections,
		humanoid.Died:Connect(function()
			Local.CleanupNPC(model)
		end)
	)
	table.insert(
		connections,
		model.Destroying:Once(function()
			Local.CleanupNPC(model)
		end)
	)
	table.insert(
		connections,
		model:GetAttributeChangedSignal("HeldItem"):Connect(function()
			Local.UpdateStealableTag(record)

			-- Every path that re-equips an NPC's item starts this animation itself right after
			-- (EquipStarterItem, CompleteBeltArrival, TryReclaimBag) — but not every path that clears
			-- HeldItem remembers to stop it (StealService's ForceDropItem didn't), so this is the
			-- single place that reliably catches all of them.
			local heldItemName = model:GetAttribute("HeldItem")
			if not heldItemName or heldItemName == "" then
				Local.StopItemIdleAnimation(record)
			end
		end)
	)
	_npcConnections[model] = connections

	table.insert(_activeNPCs, record)
	Local.ScheduleNextSprintCheck(record)
end

function Local.EquipStarterItem(record: NPCRecord)
	if math.random() >= NPCConfig.BAG_SPAWN_CHANCE then
		return
	end

	local item = ItemService.SpawnItem(NPCConfig.DEFAULT_BAG_ITEM, record.hrp.CFrame)
	if not item then
		return
	end

	if ItemService.EquipNPCItem(record.model, item) then
		Local.PlayItemIdleAnimation(record, item.Name)
	else
		item:Destroy()
	end
end

function Local.PlayItemIdleAnimation(record: NPCRecord, itemName: string)
	local itemModule = ItemsConfig.GetItem(itemName)
	local animId = itemModule and itemModule.properties and itemModule.properties.idleAnimationId
	if not animId or animId == 0 then
		return
	end

	Local.StopItemIdleAnimation(record)

	local animator = record.humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", record.humanoid)
	local animation = Instance.new("Animation")
	animation.AnimationId = `rbxassetid://{animId}`

	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Idle
	track.Looped = true
	track:Play(0.15)

	record.itemAnimTrack = track
end

function Local.StopItemIdleAnimation(record: NPCRecord)
	if not record.itemAnimTrack then
		return
	end

	record.itemAnimTrack:Stop(0.15)
	record.itemAnimTrack:Destroy()
	record.itemAnimTrack = nil
end

function Local.ScheduleRespawn()
	local delay = NPCConfig.RESPAWN_DELAY_MIN
		+ math.random() * (NPCConfig.RESPAWN_DELAY_MAX - NPCConfig.RESPAWN_DELAY_MIN)

	task.delay(delay, function()
		if RoundService.GetState() ~= "InProgress" or not _npcsFolder then
			return
		end

		local template = Local.GetRigTemplate()
		if template then
			Local.SpawnNPC(template)
		end
	end)
end

function Local.CleanupNPC(model: Model)
	local connections = _npcConnections[model]
	if connections then
		for _, conn in connections do
			if conn.Connected then
				conn:Disconnect()
			end
		end
		_npcConnections[model] = nil
	end

	for i, record in _activeNPCs do
		if record.model == model then
			Local.ClearWaypointMarkers(record)
			Local.ClearPathBlockedConnection(record)

			if record.targetNode and NodeGraph.GetNodeType(record.targetNode) == "seatnode" then
				NodeGraph.ReleaseSeatReservation(record.targetNode)
			end

			NodeGraph.SetEnRouteLine(model, nil)
			NodeGraph.SetEnRouteTransition(model, nil)
			NodeGraph.SetNPCShopZone(model, nil)

			table.remove(_activeNPCs, i)
			break
		end
	end

	if model.Parent then
		model:Destroy()
	end
end

function Local.IsDebugEnabled(): boolean
	return script:GetAttribute("Debug") == true
end

function Local.Warn(message: string)
	if not Local.IsDebugEnabled() then
		return
	end
	warn(message)
end

function Local.DebugWarn(record: NPCRecord, message: string)
	if not Local.IsDebugEnabled() then
		return
	end
	warn(`[NPC {record.uid}] {message}`)
end

function Local.GetDebugMarkersFolder(): Folder
	if not _debugMarkersFolder or not _debugMarkersFolder.Parent then
		_debugMarkersFolder = Instance.new("Folder")
		_debugMarkersFolder.Name = DEBUG_MARKERS_FOLDER_NAME
		_debugMarkersFolder.Parent = Workspace
	end
	return _debugMarkersFolder :: Folder
end

function Local.ClearWaypointMarkers(record: NPCRecord)
	if not record.waypointMarkers then
		return
	end
	for _, marker in record.waypointMarkers do
		if marker.Parent then
			marker:Destroy()
		end
	end
	record.waypointMarkers = nil
end

function Local.VisualizeWaypoints(record: NPCRecord, waypoints: { PathWaypoint })
	Local.ClearWaypointMarkers(record)

	local markers: { BasePart } = {}
	local folder = Local.GetDebugMarkersFolder()

	local rootY = record.hrp.Position.Y
	local nodeY = if record.targetNode then NodeGraph.GetNodePosition(record.targetNode).Y else rootY
	local markerY = (rootY + nodeY) / 2

	for i, waypoint in waypoints do
		local marker = Instance.new("Part")
		marker.Name = `Waypoint_{record.uid}_{i}`
		marker.Shape = Enum.PartType.Ball
		marker.Size = Vector3.new(0.6, 0.6, 0.6)
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Material = Enum.Material.Neon
		marker.Color = if waypoint.Action == Enum.PathWaypointAction.Jump
			then Color3.new(1, 0.6, 0)
			else Color3.new(0, 1, 0)
		marker.Position = Vector3.new(waypoint.Position.X, markerY, waypoint.Position.Z)
		marker.Parent = folder
		table.insert(markers, marker)
	end

	record.waypointMarkers = markers
end

-- [[ Private Functions ]] --
function Local.SnapToNearestNode(record: NPCRecord)
	local startZone = NPCConfig.LINEAR_ZONE_SEQUENCE[1]
	local zoneNodes = NodeGraph.EnumerateZoneNodes(_nodesFolder :: Instance, startZone)

	local best, bestDist = nil, math.huge
	for _, node in zoneNodes do
		local dist = (NodeGraph.GetNodePosition(node) - record.hrp.Position).Magnitude
		if dist < bestDist then
			bestDist = dist
			best = node
		end
	end

	if best then
		Local.DebugWarn(
			record,
			`snapped to {best.Name} ({startZone}), {math.floor(bestDist)} studs from spawn at {record.hrp.Position}`
		)
		Local.OnArrive(record, best)
	end
end

function Local.CancelDepartApproach(record: NPCRecord)
	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil
	record.moveStartedAt = 0
	record.prefetch = nil
	Local.ClearWaypointMarkers(record)
	Local.ClearPathBlockedConnection(record)
end

function Local.IsSeated(record: NPCRecord): boolean
	return record.humanoid.Sit or record.humanoid:GetState() == Enum.HumanoidStateType.Seated
end

function Local.ReplaceStuckSeat(record: NPCRecord)
	local seatPart = record.humanoid.SeatPart

	-- Humanoid.SeatPart can keep pointing at a Seat that's already gone (destroyed out from under it,
	-- e.g. a map reload) — nothing script-side can clear SeatPart directly, but toggling Jump off while
	-- FloorMaterial reads Air nudges the engine into dropping the stale reference on its own.
	if seatPart and not seatPart:IsDescendantOf(Workspace) then
		if record.humanoid.FloorMaterial == Enum.Material.Air and record.humanoid.Jump then
			record.humanoid.Jump = false
		end
	end

	local staleSeat: Seat? = (seatPart and seatPart:IsA("Seat") and seatPart :: Seat) or record.seatObject
	if not staleSeat or not staleSeat.Parent then
		return
	end

	local replacement = staleSeat:Clone()
	replacement.Parent = staleSeat.Parent

	local seatNode = record.currentNode
	if seatNode and NodeGraph.GetSeatObject(seatNode) == staleSeat then
		NodeGraph.SetSeatObject(seatNode, replacement)
		table.insert(
			_seatWatchConnections,
			replacement:GetPropertyChangedSignal("Occupant"):Connect(function()
				NodeGraph.SyncSeatOccupiedAttribute(seatNode :: BasePart)
			end)
		)
		NodeGraph.SyncSeatOccupiedAttribute(seatNode)
	end

	staleSeat:Destroy()
	record.humanoid.Sit = false
	record.humanoid.PlatformStand = false

	Local.DebugWarn(
		record,
		`replaced a stuck Seat ({staleSeat.Name}) with a fresh clone after {NPCConfig.UNSEAT_MAX_ATTEMPTS} failed release attempts`
	)
end

-- Walks straight out from a just-vacated seat along its LookVector before any real decision is
-- made, so the NPC doesn't immediately cut sideways across a row of neighboring seats to reach
-- its next target. Blocking (called from within the Unseat coroutine, gated by record.unseating).
function Local.WalkClearOfSeat(record: NPCRecord, seat: Seat?)
	if not seat or not seat.Parent then
		return
	end

	local clearPos = seat.Position + seat.CFrame.LookVector * NPCConfig.SEAT_STAND_CLEAR_DISTANCE
	Local.SetWalkTarget(record, clearPos)

	local deadline = os.clock() + NPCConfig.SEAT_STAND_CLEAR_TIMEOUT
	while
		record.humanoid.Parent
		and (record.hrp.Position - clearPos).Magnitude > NPCConfig.ARRIVAL_TOLERANCE
		and os.clock() < deadline
	do
		task.wait()
	end
end

-- The clear-of-seat walk can satisfy its own distance check while still mid-air (the stand-up Jump's
-- horizontal and vertical motion happen concurrently) — waiting here for the humanoid to actually be
-- grounded keeps Local.ComputePath (called once record.unseating flips false and a real decision comes
-- in) from pathfinding out of a still-elevated hrp.Position, which floats the resulting waypoints at
-- jump height instead of the real floor.
function Local.WaitForLanding(record: NPCRecord)
	local deadline = os.clock() + NPCConfig.SEAT_STAND_CLEAR_TIMEOUT
	while
		record.humanoid.Parent
		and record.humanoid.FloorMaterial == Enum.Material.Air
		and os.clock() < deadline
	do
		task.wait()
	end
end

function Local.Unseat(record: NPCRecord)
	if not record.seatObject and not Local.IsSeated(record) then
		return
	end

	if record.unseating then
		return
	end
	record.unseating = true

	record.lastRestTime = workspace:GetServerTimeNow()
	record.seatedAt = 0

	local seatToLeave = record.seatObject

	task.spawn(function()
		for _ = 1, NPCConfig.UNSEAT_MAX_ATTEMPTS do
			if not record.humanoid.Parent then
				record.seatObject = nil
				record.unseating = false
				return
			end

			if record.seatObject then
				record.seatObject:Sit(nil :: any)
			end
			record.humanoid.Sit = false
			record.humanoid.PlatformStand = false

			if record.humanoid:GetState() == Enum.HumanoidStateType.Seated then
				record.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end

			record.humanoid.Jump = true

			if not Local.IsSeated(record) and record.humanoid.SeatPart == nil then
				Local.WalkClearOfSeat(record, seatToLeave)
				Local.WaitForLanding(record)
				record.seatObject = nil
				record.unseating = false
				return
			end

			task.wait()
		end

		Local.ReplaceStuckSeat(record)
		record.seatObject = nil
		record.unseating = false
	end)
end

function Local.WalkTo(record: NPCRecord, node: BasePart)
	record.lineDwellUntil = 0

	if Local.IsSeated(record) then
		Local.Unseat(record)
		return
	end

	record.targetNode = node
	record.moveTargetPos = NodeGraph.GetMovementTargetPosition(node, NPCConfig.NODE_SPREAD_RADIUS, _nodesFolder, { record.model, _npcsFolder })
	Local.ComputePath(record)
	Local.RequestPrefetch(record, node)
end

-- [[ Private Functions — Seamless leg prefetching ]] --
function Local.RequestPrefetch(record: NPCRecord, forNode: BasePart)
	if not record.actor.Parent then
		return
	end

	local nodeType = NodeGraph.GetNodeType(forNode)
	if nodeType == "seatnode" or nodeType == "linenode" then
		return
	end
	if NodeGraph.IsTransitionNode(forNode) then
		return
	end

	local previousLink = record.currentNode and NodeGraph.GetLink(record.currentNode)
	local willArriveViaLink = previousLink ~= nil and previousLink == forNode

	local prefetch: Prefetch = {
		forNode = forNode,
		awaitingDecision = true,
		nextNode = nil,
		state = nil,
		waypoints = nil,
		path = nil,
		moveTargetPos = nil,
		alreadyThere = false,
		ready = false,
	}
	record.prefetch = prefetch

	Local.UpdateBoardingRoll(record)

	record.actor:SendMessage("Decide", {
		npc = record.model,
		nodesFolder = _nodesFolder,
		currentNode = forNode,
		lastNode = record.currentNode,
		arrivedViaLink = willArriveViaLink,
		behaviorType = record.model:GetAttribute("BehaviorType") or "Linear",
		lastRestTime = record.lastRestTime,
		willBoard = record.willBoard,
		holdingBag = Local.IsHoldingBag(record),
		pendingBagNode = record.pendingBagNode,
		confineZone = Local.GetWanderConfineZone(record),
		prefetch = true,
	})
end

function Local.GetPathAgentParams(origin: Vector3, goalPos: Vector3): { [string]: any }
	if math.abs(goalPos.Y - origin.Y) > NPCConfig.PATH_STEEP_HEIGHT_DIFF then
		return PATH_AGENT_PARAMS_STEEP
	end
	return PATH_AGENT_PARAMS
end

-- Waypoint 1 is always wherever PathfindingService snapped `originPos` onto the navmesh — walking to
-- it is usually a redundant no-op, so callers skip straight to waypoint 2. But when originPos is the
-- NPC's own live hrp.Position (a stuck-recovery retrace, not a fresh leg from a clean node arrival),
-- that snap can be a real few-stud maneuver back onto the mesh — skipping it was the only path back
-- to "stuck forever" once something wedged the NPC off it. Only skip when it's genuinely redundant.
function Local.FirstUsefulWaypointIndex(waypoints: { PathWaypoint }, originPos: Vector3): number
	if #waypoints <= 1 then
		return 1
	end
	if (waypoints[1].Position - originPos).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
		return 2
	end
	return 1
end

function Local.OnPrefetchDecided(record: NPCRecord, nextNode: BasePart?, state: string)
	local prefetch = record.prefetch
	if not prefetch or not prefetch.awaitingDecision then
		return
	end

	prefetch.awaitingDecision = false
	prefetch.nextNode = nextNode
	prefetch.state = state

	if not nextNode then
		prefetch.ready = true
		return
	end

	local originPos = NodeGraph.GetNodePosition(prefetch.forNode)
	local goalPos = NodeGraph.GetMovementTargetPosition(nextNode, NPCConfig.NODE_SPREAD_RADIUS, _nodesFolder, { record.model, _npcsFolder })
	prefetch.moveTargetPos = goalPos

	if (goalPos - originPos).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
		prefetch.alreadyThere = true
		prefetch.ready = true
		return
	end

	local path = PathfindingService:CreatePath(Local.GetPathAgentParams(originPos, goalPos))
	local computeOk = pcall(function()
		path:ComputeAsync(originPos, goalPos)
	end)

	if computeOk and path.Status == Enum.PathStatus.Success then
		prefetch.waypoints = path:GetWaypoints()
		prefetch.path = path
	else
		prefetch.waypoints = nil
	end

	prefetch.ready = true
end

function Local.ConsumePrefetch(record: NPCRecord, prefetch: Prefetch)
	local nextNode = prefetch.nextNode
	record.model:SetAttribute("AIState", prefetch.state)

	if not nextNode then
		return
	end

	if prefetch.alreadyThere then
		Local.OnArrive(record, nextNode)
		return
	end

	record.targetNode = nextNode
	record.moveTargetPos = prefetch.moveTargetPos

	local assumedOrigin = NodeGraph.GetNodePosition(prefetch.forNode)
	local drifted = (record.hrp.Position - assumedOrigin).Magnitude > NPCConfig.PREFETCH_DRIFT_TOLERANCE

	if prefetch.waypoints and not drifted then
		record.waypoints = prefetch.waypoints
		record.waypointIndex = Local.FirstUsefulWaypointIndex(prefetch.waypoints, record.hrp.Position)
		if prefetch.path then
			record.pathBlockedConn = prefetch.path.Blocked:Connect(function(blockedWaypointIndex: number)
				Local.OnPathBlocked(record, blockedWaypointIndex)
			end)
		end
		Local.VisualizeWaypoints(record, prefetch.waypoints)
		Local.MoveToWaypoint(record)
	else
		if drifted then
			Local.DebugWarn(
				record,
				`prefetch drifted {math.floor((record.hrp.Position - assumedOrigin).Magnitude)} studs from assumed origin — recomputing fresh path instead of trusting stale waypoints`
			)
		end
		record.waypoints = nil
		record.waypointIndex = nil
		Local.ClearWaypointMarkers(record)
		Local.ComputePath(record)
	end

	Local.RequestPrefetch(record, nextNode)
end

function Local.ComputePath(record: NPCRecord)
	local node = record.targetNode
	if not node then
		return
	end

	local humanoid = record.humanoid
	local hrp = record.hrp
	if humanoid.Health <= 0 or not hrp.Parent then
		return
	end

	local goalPos = record.moveTargetPos or NodeGraph.GetNodePosition(node)
	local origin = hrp.Position

	if (goalPos - origin).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
		Local.OnArrive(record, node)
		return
	end

	Local.ClearPathBlockedConnection(record)

	-- ComputeAsync yields, and nothing else updates WalkToPoint while it's pending — without this the
	-- NPC just stands still (still parked at wherever its last waypoint was) for that stretch. Walking
	-- straight toward the goal immediately closes that gap; MoveToWaypoint overrides it the moment a
	-- real path comes back.
	Local.StartLeg(record, origin, goalPos)
	Local.SetWalkTarget(record, goalPos)

	local path = PathfindingService:CreatePath(Local.GetPathAgentParams(origin, goalPos))
	local computeOk = pcall(function()
		path:ComputeAsync(origin, goalPos)
	end)

	if computeOk and path.Status == Enum.PathStatus.Success then
		local computedWaypoints = path:GetWaypoints()
		record.waypoints = computedWaypoints
		record.waypointIndex = Local.FirstUsefulWaypointIndex(computedWaypoints, origin)
		record.pathBlockedConn = path.Blocked:Connect(function(blockedWaypointIndex: number)
			Local.OnPathBlocked(record, blockedWaypointIndex)
		end)
		Local.VisualizeWaypoints(record, computedWaypoints)
		Local.MoveToWaypoint(record)
		return
	end

	record.waypoints = nil
	record.waypointIndex = nil
	Local.ClearWaypointMarkers(record)

	local targetZone = NodeGraph.GetZone(node, _nodesFolder :: Instance)
	local originZone = record.currentNode and NodeGraph.GetZone(record.currentNode, _nodesFolder :: Instance) or nil

	if targetZone == "Depart" and originZone == "Platform" then
		Local.DebugWarn(
			record,
			`PathfindingService failed crossing Platform->Depart to {node.Name} (computeOk={computeOk}, status={if computeOk
				then tostring(path.Status)
				else "n/a"}) — using direct move`
		)
		Local.MoveDirect(record, origin, goalPos)
		return
	end

	if record.currentNode then
		local ignore = { record.model, _npcsFolder }
		local bridge = NodeGraph.FindLoSBridge(_nodesFolder :: Instance, record.currentNode, node, ignore)
		if bridge then
			local bridgeWaypoints: { PathWaypoint } = {
				{ Position = NodeGraph.GetNodePosition(bridge), Action = Enum.PathWaypointAction.Walk } :: any,
				{ Position = goalPos, Action = Enum.PathWaypointAction.Walk } :: any,
			}
			record.waypoints = bridgeWaypoints
			record.waypointIndex = 1
			Local.VisualizeWaypoints(record, bridgeWaypoints)
			Local.DebugWarn(
				record,
				`PathfindingService failed to {node.Name} (computeOk={computeOk}, status={if computeOk
					then tostring(path.Status)
					else "n/a"}) — routing via LoS bridge {bridge.Name} instead of a raw direct move`
			)
			Local.MoveToWaypoint(record)
			return
		end
	end

	Local.DebugWarn(
		record,
		`PathfindingService failed to {node.Name} (computeOk={computeOk}, status={if computeOk
			then tostring(path.Status)
			else "n/a"}) — falling back to direct move`
	)
	Local.MoveDirect(record, origin, goalPos)
end

function Local.ClearPathBlockedConnection(record: NPCRecord)
	if record.pathBlockedConn then
		record.pathBlockedConn:Disconnect()
		record.pathBlockedConn = nil
	end
end

function Local.OnPathBlocked(record: NPCRecord, blockedWaypointIndex: number)
	if not record.model.Parent then
		return
	end
	if not record.targetNode or not record.waypointIndex then
		return
	end
	if blockedWaypointIndex < record.waypointIndex then
		return
	end

	Local.DebugWarn(record, `path blocked at waypoint {blockedWaypointIndex} — recomputing`)
	Local.ComputePath(record)
end

function Local.StartLeg(record: NPCRecord, originPos: Vector3, goalPos: Vector3)
	local now = os.clock()
	record.moveStartedAt = now
	record.legExpectedDuration = (goalPos - originPos).Magnitude / math.max(record.humanoid.WalkSpeed, 1)
	record.lastProgressPos = originPos
	record.lastProgressCheckAt = now
end

function Local.SetWalkTarget(record: NPCRecord, pos: Vector3)
	record.humanoid.WalkToPoint = pos
end

function Local.MoveToWaypoint(record: NPCRecord)
	local waypoints = record.waypoints
	local index = record.waypointIndex
	if not waypoints or not index then
		return
	end

	local waypoint = waypoints[index]
	if not waypoint then
		if record.targetNode then
			Local.OnArrive(record, record.targetNode)
		end
		return
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		record.humanoid.Jump = true
	end

	Local.StartLeg(record, record.hrp.Position, waypoint.Position)
	Local.SetWalkTarget(record, waypoint.Position)
end
function Local.MoveDirect(record: NPCRecord, origin: Vector3, goalPos: Vector3)
	local toGoal = goalPos - origin

	RAYCAST_PARAMS.FilterDescendantsInstances = { record.model, _npcsFolder }
	local result = Workspace:Raycast(origin, toGoal, RAYCAST_PARAMS)

	local goal = goalPos
	if result then
		local direction = toGoal.Unit
		local shortPos = result.Position - direction * NPCConfig.OBSTRUCTION_BUFFER

		goal = if (shortPos - origin):Dot(direction) > 0 then shortPos else origin
		Local.DebugWarn(record, `direct move obstructed by {result.Instance:GetFullName()} — clipping short`)
	end

	Local.StartLeg(record, origin, goal)
	Local.SetWalkTarget(record, goal)
	Local.DebugWarn(
		record,
		`WalkToPoint issued (direct) -> {goal} (WalkSpeed={record.humanoid.WalkSpeed}, currently at {record.hrp.Position})`
	)
end

function Local.RetraceToPath(record: NPCRecord): boolean
	local waypoints = record.waypoints
	if not waypoints or #waypoints == 0 then
		return false
	end

	local hrp = record.hrp
	local nearestIndex = 1
	local nearestDist = math.huge
	for i, waypoint in waypoints do
		local dist = (waypoint.Position - hrp.Position).Magnitude
		if dist < nearestDist then
			nearestDist = dist
			nearestIndex = i
		end
	end

	local nearestWaypoint = waypoints[nearestIndex]

	local path = PathfindingService:CreatePath(Local.GetPathAgentParams(hrp.Position, nearestWaypoint.Position))
	local computeOk = pcall(function()
		path:ComputeAsync(hrp.Position, nearestWaypoint.Position)
	end)

	if not computeOk or path.Status ~= Enum.PathStatus.Success then
		return false
	end

	local retraceWaypoints = path:GetWaypoints()
	local rejoined = table.clone(retraceWaypoints)
	for i = nearestIndex + 1, #waypoints do
		table.insert(rejoined, waypoints[i])
	end

	Local.ClearPathBlockedConnection(record)
	record.waypoints = rejoined
	record.waypointIndex = Local.FirstUsefulWaypointIndex(retraceWaypoints, hrp.Position)
	record.pathBlockedConn = path.Blocked:Connect(function(blockedWaypointIndex: number)
		Local.OnPathBlocked(record, blockedWaypointIndex)
	end)
	Local.VisualizeWaypoints(record, rejoined)
	Local.MoveToWaypoint(record)

	return true
end

function Local.CheckStuck(record: NPCRecord, goalPos: Vector3)
	local hrp = record.hrp
	local now = os.clock()
	local elapsed = now - record.moveStartedAt

	if elapsed <= record.legExpectedDuration * NPCConfig.LEG_TIMEOUT_GRACE_MULTIPLIER then
		return
	end

	if elapsed > NPCConfig.STUCK_TIMEOUT then
		local stuckNode = record.targetNode :: BasePart
		local originNode = record.currentNode
		local rerouteNode = originNode
			and NodeGraph.FindNearestNode(
				_nodesFolder :: Instance,
				originNode,
				{ NodeGraph.GetZone(originNode, _nodesFolder :: Instance) },
				{ stuckNode, record.lastNode },
				{ record.model, _npcsFolder },
				nil,
				{ seatnode = true, linenode = true }
			)

		if rerouteNode then
			Local.DebugWarn(
				record,
				`stuck-timeout toward {stuckNode.Name} (still {math.floor((hrp.Position - goalPos).Magnitude)} studs away) — rerouting to {rerouteNode.Name} instead`
			)
			record.targetNode = rerouteNode
			record.moveTargetPos = nil
			record.waypoints = nil
			record.waypointIndex = nil
			record.stuckNudgeAttempts = 0
			Local.ComputePath(record)
		else
			Local.DebugWarn(
				record,
				`stuck-timeout toward {stuckNode.Name} (still {math.floor((hrp.Position - goalPos).Magnitude)} studs away), no reroute candidate nearby — forcing arrival`
			)
			Local.OnArrive(record, stuckNode)
		end
		return
	end

	if now - record.lastProgressCheckAt < NPCConfig.STUCK_NUDGE_CHECK_INTERVAL then
		return
	end
	record.lastProgressCheckAt = now

	local moved = (hrp.Position - record.lastProgressPos).Magnitude
	local progressed = moved >= NPCConfig.STUCK_NUDGE_DISTANCE * NPCConfig.STUCK_PROGRESS_RATIO

	record.lastProgressPos = hrp.Position

	if progressed then
		record.moveStartedAt = now
		record.legExpectedDuration = (goalPos - hrp.Position).Magnitude / math.max(record.humanoid.WalkSpeed, 1)
		record.stuckNudgeAttempts = 0
		return
	end

	local toGoal = goalPos - hrp.Position
	if toGoal.Magnitude < 0.05 then
		return
	end

	if not Local.RetraceToPath(record) then
		Local.SetWalkTarget(record, goalPos)
	end

	record.stuckNudgeAttempts += 1

	-- A plain nudge toward the goal is tried first — cheap, and usually enough on its own. Only
	-- once that alone keeps failing to make progress (attempt 2+) do we escalate to a back+side
	-- step, since a straight push just wedges them harder into whatever's snagging them (a table
	-- corner, a chair leg). The escalation has its own longer cooldown so it doesn't fire on
	-- every 0.5s check once triggered — it needs room to actually clear the obstruction.
	if record.stuckNudgeAttempts > 1 and now - record.lastBackSideNudgeAt >= NPCConfig.STUCK_BACKSIDE_NUDGE_COOLDOWN then
		record.lastBackSideNudgeAt = now

		local backDir = -hrp.CFrame.LookVector
		local rightDir = hrp.CFrame.RightVector
		local sideDir = if rightDir:Dot(toGoal.Unit) >= 0 then rightDir else -rightDir

		hrp.CFrame += backDir * NPCConfig.STUCK_NUDGE_BACK_DISTANCE + sideDir * NPCConfig.STUCK_NUDGE_SIDE_DISTANCE
		Local.DebugWarn(
			record,
			`no progress toward {record.targetNode.Name} — front nudge alone hasn't worked, stepping back+side to clear the obstruction`
		)
	else
		hrp.CFrame += toGoal.Unit * NPCConfig.STUCK_NUDGE_DISTANCE
		Local.DebugWarn(
			record,
			`no progress toward {record.targetNode.Name} — retracing to path and nudging {NPCConfig.STUCK_NUDGE_DISTANCE} studs toward goal`
		)
	end
end

-- [[ Private Functions — Conveyor node (bag-in-transit) ]] --
function Local.StartConveyorTransit(record: NPCRecord, node: BasePart)
	local heldItemName = record.model:GetAttribute("HeldItem")
	local pickupNode = NodeGraph.GetPickupNode(node)

	if not heldItemName or heldItemName == "" or not pickupNode then
		return
	end

	local bag = ItemService.ForceDropItem(record.model)
	if not bag or not bag.PrimaryPart then
		return
	end
	Local.StopItemIdleAnimation(record)

	-- ForceDropItem (ClearEquipped) tags it Interactable like any normal world-dropped item —
	-- suppress that while it's riding the belt so a player can't snatch it off mid-transit. Restored
	-- right before the re-equip attempt in CompleteBeltArrival/TryReclaimBag, so it's only ever
	-- pickup-able if that re-equip genuinely fails and it's left stranded at the end.
	CollectionService:RemoveTag(bag, "Interactable")

	local startSub = NodeGraph.GetSubNode(node, "Start")
	local endSub = NodeGraph.GetSubNode(node, "End")
	local startPos = startSub and NodeGraph.GetNodePosition(startSub) or NodeGraph.GetNodePosition(node)
	local endPos = endSub and NodeGraph.GetNodePosition(endSub) or NodeGraph.GetNodePosition(pickupNode)

	bag:SetAttribute("OwnerNPCUID", record.uid)
	bag:SetAttribute("OnBelt", true)

	-- Matches ProjectileSimulation's multi-part handling (see Local.InstantiateBullet): only the
	-- PrimaryPart is anchored and CFrame-driven; welded descendants stay unanchored so their
	-- WeldConstraint physically drags them along. PivotTo-ing the whole assembly here — after
	-- ClearEquipped had already left every part unanchored — was leaving non-primary parts stuck at
	-- their stale in-hand offset for the entire ride, only correcting once re-equipped at the end.
	local primaryPart = bag.PrimaryPart :: BasePart
	for _, part in bag:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = part == primaryPart
		end
	end

	primaryPart.CFrame = CFrame.new(startPos)

	local info: BeltBagInfo = {
		npcUID = record.uid,
		conveyorNode = node,
		startPos = startPos,
		endPos = endPos,
		startTime = workspace:GetServerTimeNow(),
		travelTime = NPCConfig.BELT_TRAVEL_TIME,
		arrived = false,
		indicatorFlashed = false,
	}
	_beltBags[bag] = info

	bag.Destroying:Once(function()
		_beltBags[bag] = nil
	end)

	Local.RunBeltTransit(bag, info)

	record.pendingBagNode = pickupNode
end

function Local.RunBeltTransit(bag: Model, info: BeltBagInfo)
	task.spawn(function()
		while true do
			if _beltBags[bag] ~= info then
				return
			end

			-- Interactable is suppressed for the whole ride now, so its absence no longer signals
			-- "someone already took it" — only destruction does.
			if not bag.Parent then
				_beltBags[bag] = nil
				local owner = Local.FindRecordByUid(info.npcUID)
				if owner then
					owner.pendingBagNode = nil
				end
				return
			end

			local elapsed = workspace:GetServerTimeNow() - info.startTime
			local alpha = math.clamp(elapsed / info.travelTime, 0, 1)
			local primaryPart = bag.PrimaryPart
			if primaryPart then
				primaryPart.CFrame = CFrame.new(info.startPos:Lerp(info.endPos, alpha))
			end

			if not info.indicatorFlashed and alpha >= 0.5 then
				info.indicatorFlashed = true
				Local.FlashIndicator(info.conveyorNode, bag)
			end

			if alpha >= 1 then
				info.arrived = true
				Local.CompleteBeltArrival(bag, info)
				return
			end

			task.wait(0.1)
		end
	end)
end

-- Flashes the conveyor's "Indicator" model (an ObjectValue on the node — see NodeGraph.GetIndicatorModel)
-- red/green based on whether the item riding the belt actually contains contraband.
function Local.FlashIndicator(conveyorNode: BasePart, item: Model)
	local indicatorModel = NodeGraph.GetIndicatorModel(conveyorNode)
	if not indicatorModel then
		Local.Warn(`[NpcService] FlashIndicator({conveyorNode:GetFullName()}) — no "Indicator" ObjectValue found on the node (or its Value isn't a Model)`)
		return
	end

	local primaryPart = indicatorModel.PrimaryPart
	if not primaryPart then
		Local.Warn(`[NpcService] FlashIndicator({conveyorNode:GetFullName()}) — Indicator model "{indicatorModel:GetFullName()}" has no PrimaryPart set`)
		return
	end

	local originalColor = primaryPart:GetAttribute("OriginalColor")
	if typeof(originalColor) ~= "Color3" then
		originalColor = primaryPart.Color
		primaryPart:SetAttribute("OriginalColor", originalColor)
	end

	local hasContraband = ItemService.GetContrabandItemCount(item) > 0
	primaryPart.Color = hasContraband and INDICATOR_CONTRABAND_COLOR or INDICATOR_CLEAN_COLOR

	task.delay(INDICATOR_RESET_DELAY, function()
		if primaryPart and primaryPart.Parent then
			primaryPart.Color = originalColor
		end
	end)
end

function Local.CompleteBeltArrival(bag: Model, info: BeltBagInfo)
	local record = Local.FindRecordByUid(info.npcUID)
	if not record then
		return
	end
	if record.pendingBagNode ~= record.currentNode then
		return
	end

	_beltBags[bag] = nil
	record.pendingBagNode = nil

	if bag.Parent then
		bag:SetAttribute("OnBelt", nil)

		-- Restore Interactable right before attempting to reclaim it — WeldToHand removes it again on
		-- success, so it only stays pickup-able if EquipNPCItem genuinely fails and it's left stranded.
		CollectionService:AddTag(bag, "Interactable")
		if ItemService.EquipNPCItem(record.model, bag) then
			Local.PlayItemIdleAnimation(record, bag.Name)
		end
	end
end

function Local.TryReclaimBag(record: NPCRecord)
	local targetBag: Model? = nil
	local targetInfo: BeltBagInfo? = nil

	for bag, info in _beltBags do
		if info.npcUID == record.uid then
			targetBag, targetInfo = bag, info
			break
		end
	end

	if not targetBag or not targetInfo then
		record.pendingBagNode = nil
		return
	end

	if not targetInfo.arrived then
		return
	end

	_beltBags[targetBag] = nil
	record.pendingBagNode = nil

	if targetBag.Parent then
		targetBag:SetAttribute("OnBelt", nil)
		CollectionService:AddTag(targetBag, "Interactable")
		if ItemService.EquipNPCItem(record.model, targetBag) then
			Local.PlayItemIdleAnimation(record, targetBag.Name)
		end
	end
end

function Local.OnArrive(record: NPCRecord, node: BasePart)
	record.lastNode = record.currentNode
	record.currentNode = node
	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil
	record.moveStartedAt = 0
	record.stuckNudgeAttempts = 0
	Local.ClearWaypointMarkers(record)
	Local.ClearPathBlockedConnection(record)

	local previousLink = record.lastNode and NodeGraph.GetLink(record.lastNode)
	record.arrivedViaLink = previousLink ~= nil and previousLink == node

	if record.pendingBagNode == node then
		Local.TryReclaimBag(record)
	end

	if NodeGraph.IsConveyorNode(node) then
		Local.StartConveyorTransit(record, node)
	end

	if NodeGraph.IsTransitionNode(node) or NodeGraph.IsConveyorNode(node) then
		NodeGraph.SetEnRouteTransition(record.model, nil)
	end

	local arrivalZone = NodeGraph.GetZone(node, _nodesFolder :: Instance)

	-- A shop's Transition Node links back to one in Concourse, so the return trip out is ALSO
	-- a link crossing between two Transition Nodes — gating on IsShopZone(arrivalZone) as well
	-- keeps that return arrival from being mistaken for a fresh shop entry and re-triggering the
	-- dwell timer / Wander flip.
	local isShopDetourArrival = NodeGraph.IsShopZone(arrivalZone)
		and record.arrivedViaLink
		and NodeGraph.IsTransitionNode(node)
		and record.lastNode
		and NodeGraph.IsTransitionNode(record.lastNode)

	if isShopDetourArrival then
		record.wanderDwellUntil = workspace:GetServerTimeNow()
			+ math.random(NPCConfig.SHOP_DWELL_MIN, NPCConfig.SHOP_DWELL_MAX)
		if record.model:GetAttribute("BehaviorType") ~= "Wander" then
			record.model:SetAttribute("BehaviorType", "Wander")
		end
	end

	-- Concourse Loitering's "wander" outcome (Linear.luau flags this on the NPC rather than
	-- setting record fields directly — behaviors run on the parallel Actor and can only touch
	-- Instance attributes, never the private NPCRecord table).
	local startedConcourseWander = record.model:GetAttribute("PendingConcourseLoiterWander") == true
	if startedConcourseWander then
		record.model:SetAttribute("PendingConcourseLoiterWander", nil)
		record.model:SetAttribute("WanderConfineZone", "Concourse")
		record.wanderDwellUntil = workspace:GetServerTimeNow()
			+ math.random(NPCConfig.CONCOURSE_WANDER_MIN, NPCConfig.CONCOURSE_WANDER_MAX)
		if record.model:GetAttribute("BehaviorType") ~= "Wander" then
			record.model:SetAttribute("BehaviorType", "Wander")
		end
	end

	-- Entering a shop zone confines Wander's candidate search to that zone alone (see
	-- Wander.luau's ctx.confineZone) and tracks live occupancy on the zone folder's NPCCount
	-- attribute; leaving one (arriving anywhere outside it) releases both.
	if NodeGraph.IsShopZone(arrivalZone) then
		record.model:SetAttribute("WanderConfineZone", arrivalZone)
		local zoneFolder = NodeGraph.GetZoneFolder(_nodesFolder :: Instance, arrivalZone)
		if zoneFolder then
			NodeGraph.SetNPCShopZone(record.model, zoneFolder)
		end
	else
		NodeGraph.SetNPCShopZone(record.model, nil)
	end

	if arrivalZone ~= "Concourse" then
		record.model:SetAttribute("ConcourseLoiterRolled", nil)
		NodeGraph.SetPendingShopTransition(record.model, nil)

		-- TEMP: matches Linear's shop-debug highlight — clears once the loiter roll it was tracking
		-- is no longer live.
		local shopDebugHighlight = record.model:FindFirstChild("ShopDebugHighlight")
		if shopDebugHighlight then
			shopDebugHighlight:Destroy()
		end
	end

	local isSeatNode = NodeGraph.GetNodeType(node) == "seatnode"
	if isSeatNode then
		record.seatedAt = workspace:GetServerTimeNow()
		NodeGraph.ReleaseSeatReservation(node)

		local seatObject = NodeGraph.GetSeatObject(node)
		if seatObject then
			seatObject:Sit(record.humanoid)
			record.humanoid.Sit = true
			record.seatObject = seatObject
		end
	end

	record.lineDwellUntil = Queueing.StartDwell(node) or 0

	local isFinalDepartNode = NodeGraph.GetZone(node, _nodesFolder :: Instance) == "Depart"
		and NodeGraph.GetLink(node) == nil

	if isFinalDepartNode then
		record.departArrivedAt = workspace:GetServerTimeNow()
	else
		record.departArrivedAt = 0
	end

	local waitingForBag = record.pendingBagNode == node

	local prefetch = record.prefetch
	if prefetch and prefetch.forNode == node then
		-- A prefetch computed before this arrival's BehaviorType/WanderConfineZone flip is stale —
		-- it was decided under the old mode and can't be trusted (e.g. a Linear-computed hop that
		-- ignores the Wander confinement that only just took effect). Discard and force a fresh ask.
		if isSeatNode or waitingForBag or isShopDetourArrival or startedConcourseWander then
			record.prefetch = nil
		elseif prefetch.ready then
			record.prefetch = nil
			Local.ConsumePrefetch(record, prefetch)
		end
	end
end

function Local.CheckWaypointProgress(record: NPCRecord)
	if not record.targetNode then
		return
	end

	local hrp = record.hrp
	if not hrp.Parent then
		return
	end

	if record.waypoints and record.waypointIndex then
		local waypoint = record.waypoints[record.waypointIndex]
		if not waypoint then
			return
		end

		if (hrp.Position - waypoint.Position).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
			if record.waypointIndex == #record.waypoints then
				Local.OnArrive(record, record.targetNode)
			else
				record.waypointIndex += 1
				Local.MoveToWaypoint(record)
			end
			return
		end

		Local.CheckStuck(record, waypoint.Position)
		return
	end

	local goalPos = record.moveTargetPos or NodeGraph.GetNodePosition(record.targetNode :: BasePart)
	local distance = (hrp.Position - goalPos).Magnitude

	if distance <= NPCConfig.ARRIVAL_TOLERANCE then
		Local.OnArrive(record, record.targetNode :: BasePart)
		return
	end

	Local.CheckStuck(record, goalPos)
end

-- [[ Private Functions — Decision report (fired from the Actor) ]] --
function Local.FindRecordByModel(npc: Model): NPCRecord?
	for _, record in _activeNPCs do
		if record.model == npc then
			return record
		end
	end
	return nil
end

function Local.FindRecordByUid(uid: string): NPCRecord?
	for _, record in _activeNPCs do
		if record.uid == uid then
			return record
		end
	end
	return nil
end

function Local.OnDecisionReported(npc: Model, nextNode: BasePart?, state: string, isPrefetch: boolean?)
	local record = Local.FindRecordByModel(npc)
	if not record then
		return
	end

	-- A decision requested before Alert/Panic interrupted this NPC is stale by the time it reports
	-- back — discard it instead of letting it stomp the reaction's own movement/state.
	if record.reactionState ~= "None" then
		record.awaitingDecision = false
		record.busy = false
		return
	end

	if isPrefetch then
		Local.OnPrefetchDecided(record, nextNode, state)
		return
	end

	record.awaitingDecision = false
	npc:SetAttribute("AIState", state)

	if nextNode then
		local ok, err = pcall(Local.WalkTo, record, nextNode)
		if not ok then
			Local.Warn(`[NpcService] WalkTo error for {record.uid}: {err}`)
		end
	end

	record.busy = false
end

-- [[ Private Functions — Alert / Panic / Contagion ]] --

-- Pulls an NPC out of whatever node-specific holding state it's in (seat, line dwell, in-flight
-- decision/prefetch) before switching it into a reaction state (Alert/Panicking).
function Local.InterruptForReaction(record: NPCRecord)
	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil
	record.moveStartedAt = 0
	record.prefetch = nil
	record.awaitingDecision = false
	record.lineDwellUntil = 0
	record.pendingBagNode = nil
	Local.ClearWaypointMarkers(record)
	Local.ClearPathBlockedConnection(record)

	if record.seatObject or Local.IsSeated(record) then
		Local.Unseat(record)
	end
end

-- Single source of truth for WalkSpeed: Panicking always wins, then an ambient sprint burst, else the
-- NPC's own jittered base speed. Called any time either flag changes so the two systems never fight
-- or compound each other's multiplier.
function Local.RefreshWalkSpeed(record: NPCRecord)
	if record.reactionState == "Panicking" then
		record.humanoid.WalkSpeed = record.baseWalkSpeed * NPCConfig.PANIC_SPEED_MULTIPLIER
	elseif record.sprinting then
		record.humanoid.WalkSpeed = record.baseWalkSpeed * NPCConfig.SPRINT_SPEED_MULTIPLIER
	else
		record.humanoid.WalkSpeed = record.baseWalkSpeed
	end
end

-- Reconciles a reaction-displaced NPC back into the node graph from wherever it physically ended up
-- (unlike Local.SnapToNearestNode, which is Lobby-zone-locked and only correct at initial spawn).
function Local.ResumeAfterReaction(record: NPCRecord)
	record.reactionState = "None"
	record.model:SetAttribute("AIState", "Commuting")

	if not record.actor.Parent then
		return
	end

	Local.RefreshWalkSpeed(record)

	-- InterruptForReaction stopped this on the way in (Alert/Panic own movement, no idle sway needed
	-- mid-reaction) — nothing restarts it once the reaction ends, so a still-held item was left frozen.
	local heldItemName = record.model:GetAttribute("HeldItem")
	if heldItemName and heldItemName ~= "" then
		Local.PlayItemIdleAnimation(record, heldItemName)
	end

	if not _nodesFolder then
		return
	end

	local best, bestDist = nil, math.huge
	for _, node in NodeGraph.EnumerateAllNodes(_nodesFolder :: Instance) do
		local dist = (NodeGraph.GetNodePosition(node) - record.hrp.Position).Magnitude
		if dist < bestDist then
			bestDist = dist
			best = node
		end
	end

	if best then
		Local.OnArrive(record, best)
	end
end

function Local.EnterAlert(record: NPCRecord, sourcePosition: Vector3?)
	if record.reactionState ~= "None" then
		return
	end

	Local.InterruptForReaction(record)
	record.reactionState = "Alert"
	record.model:SetAttribute("AIState", "Alert")
	Local.SetWalkTarget(record, record.hrp.Position) -- pause in place to "look"

	local epoch = record.reactionEpoch + 1
	record.reactionEpoch = epoch

	task.delay(NPCConfig.ALERT_LOOK_DURATION, function()
		if not record.actor.Parent then return end
		if record.reactionState ~= "Alert" then return end
		if record.reactionEpoch ~= epoch then return end

		if math.random() < NPCConfig.ALERT_ESCALATE_CHANCE then
			Local.EnterPanic(record, sourcePosition)
		else
			Local.ResumeAfterReaction(record)
		end
	end)
end

-- sourcePosition, when given, is the threat NPCs flee from (ragdoll location, or the panicking NPC
-- that contagion is spreading from) — PanicWander biases its random points away from it. Omitted for
-- the direct steal-alert victim, which has no external threat position to run from.
function Local.EnterPanic(record: NPCRecord, sourcePosition: Vector3?)
	if record.reactionState ~= "Panicking" then
		Local.InterruptForReaction(record)
		record.reactionState = "Panicking"
		record.model:SetAttribute("AIState", "Panicking")
		Local.RefreshWalkSpeed(record)
		Local.PropagateContagion(record)
	end

	-- Token pattern (mirrors the decision/rest epoch guards elsewhere in this file) so an NPC
	-- re-triggered into Panic while already panicking extends the duration correctly, and the
	-- previous PanicWander recursion chain retires itself instead of running alongside a new one.
	local epoch = record.reactionEpoch + 1
	record.reactionEpoch = epoch

	Local.PanicWander(record, epoch, sourcePosition)

	task.delay(NPCConfig.PANIC_DURATION, function()
		if not record.actor.Parent then return end
		if record.reactionState ~= "Panicking" then return end
		if record.reactionEpoch ~= epoch then return end
		Local.ResumeAfterReaction(record)
	end)
end

function Local.PanicWander(record: NPCRecord, epoch: number, sourcePosition: Vector3?)
	if record.reactionState ~= "Panicking" or record.reactionEpoch ~= epoch then
		return
	end

	local origin = record.hrp.Position
	local dist = math.random() * NPCConfig.PANIC_RADIUS

	local awayFromSource = sourcePosition and (origin - sourcePosition)
	local baseAngle: number
	if awayFromSource and awayFromSource.Magnitude > 1 then
		baseAngle = math.atan2(awayFromSource.Z, awayFromSource.X)
	else
		baseAngle = math.random() * math.pi * 2 -- no usable source direction (too close/none) — flee blindly
	end

	local angle = baseAngle + (math.random() * 2 - 1) * NPCConfig.PANIC_FLEE_CONE_ANGLE
	local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

	Local.SetWalkTarget(record, origin + offset)

	task.delay(math.random(1, 2), function()
		if not record.actor.Parent then return end
		Local.PanicWander(record, epoch, sourcePosition)
	end)
end

-- Radius + raycast line-of-sight gated. Spreads from the panicking NPC's own position (not the
-- original trigger), so repeated propagation produces an outward wave rather than a fixed blast, and
-- each newly-infected NPC flees away from the one that infected it.
function Local.PropagateContagion(source: NPCRecord)
	local originPos = source.hrp.Position

	for _, other in _activeNPCs do
		if other == source then continue end
		if other.reactionState == "Panicking" then continue end

		local otherPos = other.hrp.Position
		if (otherPos - originPos).Magnitude > NPCConfig.PANIC_RADIUS then continue end
		if not NodeGraph.HasClearLine(originPos, otherPos, { _npcsFolder }) then continue end

		if math.random() < NPCConfig.CONTAGION_CHANCE then
			Local.EnterPanic(other, originPos)
		end
	end
end

-- [[ Private Functions — Ambient Sprinting ]] --

-- Purely cosmetic crowd flavor — independent of Alert/Panic, self-recurses for the NPC's entire
-- lifetime. Skips rolling (but keeps the chain alive) while a reaction owns the NPC's movement.
function Local.ScheduleNextSprintCheck(record: NPCRecord)
	task.delay(math.random(NPCConfig.SPRINT_CHECK_INTERVAL_MIN, NPCConfig.SPRINT_CHECK_INTERVAL_MAX), function()
		if not record.actor.Parent then return end

		if
			record.reactionState == "None"
			and not record.sprinting
			and math.random() < NPCConfig.SPRINT_CHANCE
		then
			Local.StartSprint(record)
		end

		Local.ScheduleNextSprintCheck(record)
	end)
end

function Local.StartSprint(record: NPCRecord)
	record.sprinting = true
	Local.RefreshWalkSpeed(record)

	task.delay(math.random(NPCConfig.SPRINT_DURATION_MIN, NPCConfig.SPRINT_DURATION_MAX), function()
		if not record.actor.Parent then return end
		record.sprinting = false
		Local.RefreshWalkSpeed(record)
	end)
end

-- [[ Public Functions ]] --

function Shared.FindNPCById(uid: string?): Model?
	if not uid or uid == "" then
		return nil
	end

	local record = nil
	for _, r in _activeNPCs do
		if r.uid == uid then
			record = r
			break
		end
	end

	return record and record.model
end

function Shared.IsNPC(npc: Model): boolean
	return Local.FindRecordByModel(npc) ~= nil
end

function Shared.GetNPCKind(npc: Model): NPCKind?
	if Shared.IsNPC(npc) then
		return "Crowd"
	end
	return nil
end

-- Called by StealService whenever an NPC is successfully stolen from or catches a Smuggler mid-steal.
function Shared.ForceAlert(npc: Model)
	local record = Local.FindRecordByModel(npc)
	if not record then
		return
	end

	Local.EnterAlert(record)
end

-- Public hook for the violence-witness reaction wired to RagdollService.OnRagdolled in Shared.Init,
-- and for any future caller (e.g. Gate Lockdown) — NpcService never depends on the caller existing.
function Shared.ForcePanic(position: Vector3, radius: number, requireLineOfSight: boolean?)
	for _, record in _activeNPCs do
		local npcPos = record.hrp.Position
		if (npcPos - position).Magnitude > radius then
			continue
		end

		if requireLineOfSight and not NodeGraph.HasClearLine(position, npcPos, { _npcsFolder }) then
			continue
		end

		Local.EnterPanic(record, position)
	end
end

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	Local.DespawnAll()
end

return Shared
