--|| Services
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)
local NodeGraph = require(script.NodeGraph)

local RoundService = require(script.Parent.RoundService)
local MapService = require(script.Parent.MapService)

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
	arrivedViaLink: boolean,
	awaitingDecision: boolean,
	decisionRequestedAt: number,
	lastRestTime: number,
	seatedAt: number,
	seatObject: Seat?,
	lineDwellUntil: number,
	departArrivedAt: number,
	pendingRepath: boolean,
	pathBlockedConn: RBXScriptConnection?,
	waypointMarkers: { BasePart }?,
	prefetch: Prefetch?,
}

--|| Variables
local _connections: { RBXScriptConnection } = {}
local _npcConnections: { [Model]: { RBXScriptConnection } } = {}
local _activeNPCs: { NPCRecord } = {}
local _npcsFolder: Folder? = nil
local _nodesFolder: Instance? = nil
local _nextUid = 0
local _debugMarkersFolder: Folder? = nil
local _seatWatchConnections: { RBXScriptConnection } = {}

local Local = {}
local Shared = {}

Local.decisionReportEvent = Instance.new("BindableEvent")

--|| Constants
local NPC_FOLDER_NAME = "NPCs"
local DEBUG_MARKERS_FOLDER_NAME = "NPCDebugMarkers" -- TEMP: waypoint visualizer while debugging pathfinding

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
-- Makes this raycast respect the same PhysicsService collision-group
-- exemptions NPCs actually walk under — a plain Raycast ignores
-- CollisionGroupSetCollidable entirely and only cares about CanCollide, so
-- without this, MoveDirect's obstruction check would still treat an open
-- door (still CanCollide=true, just non-collidable with "NPC" specifically —
-- see GateService/CharacterService's DoorOpen group) as a solid wall and
-- clip the goal short of it.
RAYCAST_PARAMS.CollisionGroup = "NPC"

local PATH_AGENT_PARAMS = {
	AgentRadius = NPCConfig.PATH_AGENT_RADIUS,
	AgentHeight = NPCConfig.PATH_AGENT_HEIGHT,
	AgentCanJump = NPCConfig.PATH_AGENT_CAN_JUMP,
	AgentCanClimb = NPCConfig.PATH_AGENT_CAN_CLIMB,
	WaypointSpacing = NPCConfig.PATH_WAYPOINT_SPACING,
}

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, RoundService.OnStateChange:Connect(Local.OnRoundStateChange))
	table.insert(_connections, Local.decisionReportEvent.Event:Connect(Local.OnDecisionReported))

	table.insert(_connections, RunService.Heartbeat:Connect(function(_dt: number)
		if RoundService.GetState() ~= "InProgress" then return end

		for _, record in _activeNPCs do
			task.spawn(function()
				if not record.actor.Parent then return end

				if record.targetNode then
					Local.CheckWaypointProgress(record)
					return
				end

				if record.awaitingDecision then
					if os.clock() - record.decisionRequestedAt > NPCConfig.DECISION_TIMEOUT then
						record.awaitingDecision = false
					else
						return
					end
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

				if record.seatedAt > 0 and workspace:GetServerTimeNow() - record.seatedAt < NPCConfig.SEAT_REST_DURATION then
					return
				end

				-- Lingering at the front Line Node: same hold-still gate as Seat Node rest.
				if record.lineDwellUntil > 0 and workspace:GetServerTimeNow() < record.lineDwellUntil then
					return
				end

				-- Waiting at the final Depart node: stays on Linear the whole
				-- time (no behavior switch) — only intercept here once
				-- actually eligible to board, otherwise fall through so it
				-- keeps requesting fresh decisions (Linear naturally has
				-- nowhere else to go from the terminal node and just stays
				-- put) instead of freezing solid until the next cycle.
				if record.departArrivedAt > 0
					and Workspace:GetAttribute("BoardingOpen")
					and workspace:GetServerTimeNow() - record.departArrivedAt >= NPCConfig.BOARD_DWELL then
					-- task.defer(Local.CleanupNPC, record.model)
					-- Local.ScheduleRespawn()
					return
				end

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
				})
			end)
		end
	end))

	local currentState = RoundService.GetState()
	if currentState == "Starting" or currentState == "InProgress" then
		Local.OnRoundStateChange(currentState)
	end
end

function Shared.Start()

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
	Local.DespawnAll() -- safety net in case of an unclean previous round

	_npcsFolder = Instance.new("Folder")
	_npcsFolder.Name = NPC_FOLDER_NAME
	_npcsFolder.Parent = Workspace

	local activeMap = MapService.GetActiveMap()
	if not activeMap then
		warn("[NpcService] No active map — cannot build node graph")
		return
	end

	local nodesFolder = activeMap:FindFirstChild("Nodes")
	if not nodesFolder then
		warn("[NpcService] Active map has no 'Nodes' Folder — NPCs will have nowhere to walk")
		return
	end
	_nodesFolder = nodesFolder
	Local.ResetLineSlots(nodesFolder)
	Local.WatchSeats(nodesFolder)

	local template = Local.GetRigTemplate()
	if not template then return end

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
		if NodeGraph.GetNodeType(node) ~= "seatnode" then continue end

		NodeGraph.ReleaseSeatReservation(node)
		NodeGraph.SyncSeatOccupiedAttribute(node)

		local seat = NodeGraph.GetSeatObject(node)
		if not seat then continue end

		table.insert(_seatWatchConnections, seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			NodeGraph.SyncSeatOccupiedAttribute(node)
		end))
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
		warn("[NpcService] ReplicatedStorage.Assets.Rig not found or not a Model")
		return nil
	end
	return rig
end

function Local.GetSpawnZone(): BasePart?
	local activeMap = MapService.GetActiveMap()
	if not activeMap then return nil end

	local spawnsFolder = activeMap:FindFirstChild("Spawns")
	if not spawnsFolder then return nil end

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

function Local.GetSpawnCFrame(): CFrame
	local zone = Local.GetSpawnZone()
	if zone then
		local position = Local.GetRandomPositionInPart(zone)
		return CFrame.new(position) * (zone.CFrame - zone.CFrame.Position)
	end

	warn("[NpcService] Active map has no Spawns.NPC part — spawning at the world origin")
	return CFrame.new()
end

function Local.GetActorScriptTemplate(): Script?
	local template = script:FindFirstChild("ActorScript")
	if not template or not template:IsA("Script") then
		warn("[NpcService] ActorScript template not found")
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
	if not _npcsFolder then return end

	local model = template:Clone()
	model.Name = "NPC"
	model:PivotTo(Local.GetSpawnCFrame())
	model.Parent = _npcsFolder

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		warn("[NpcService] Rig template is missing a Humanoid/HumanoidRootPart")
		model:Destroy()
		return
	end

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

	-- Randomized per-NPC offset so the crowd doesn't move in lockstep.
	humanoid.WalkSpeed = NPCConfig.WALK_SPEED + (math.random() * 2 - 1) * NPCConfig.WALK_SPEED_JITTER

	_nextUid += 1
	local uid = `NPC_{_nextUid}_{math.floor(workspace:GetServerTimeNow() * 1000)}`
	model:SetAttribute("UID", uid)
	model:SetAttribute("Kind", "Crowd")
	model:SetAttribute("BehaviorType", "Linear") -- no trait rolling yet — every Crowd NPC uses the same Behavior module

	local actor = Local.InjectActor(model)
	warn(`[NpcService] Spawned {uid} at {model:GetPivot().Position} (BehaviorType=Linear, Nodes={_nodesFolder and _nodesFolder:GetFullName() or "nil"}, unanchored {anchoredCount} part(s), PlatformStand={humanoid.PlatformStand}, Sit={humanoid.Sit}, state={humanoid:GetState().Name})`)

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
		arrivedViaLink = false,
		awaitingDecision = false,
		decisionRequestedAt = 0,
		lastRestTime = 0,
		seatedAt = 0,
		seatObject = nil,
		lineDwellUntil = 0,
		departArrivedAt = 0,
		pendingRepath = false,
		pathBlockedConn = nil,
		waypointMarkers = nil,
		prefetch = nil,
	}

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, humanoid.Died:Connect(function()
		Local.CleanupNPC(model)
	end))
	table.insert(connections, model.Destroying:Once(function()
		Local.CleanupNPC(model)
	end))
	_npcConnections[model] = connections

	table.insert(_activeNPCs, record)
end

function Local.ScheduleRespawn()
	local delay = NPCConfig.RESPAWN_DELAY_MIN + math.random() * (NPCConfig.RESPAWN_DELAY_MAX - NPCConfig.RESPAWN_DELAY_MIN)

	task.delay(delay, function()
		if RoundService.GetState() ~= "InProgress" or not _npcsFolder then return end

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

			table.remove(_activeNPCs, i)
			break
		end
	end

	if model.Parent then
		model:Destroy()
	end
end

function Local.DebugWarn(record: NPCRecord, message: string)
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
	if not record.waypointMarkers then return end
	for _, marker in record.waypointMarkers do
		if marker.Parent then marker:Destroy() end
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
		Local.OnArrive(record, best)
	end
end

function Local.WalkTo(record: NPCRecord, node: BasePart)
	record.lineDwellUntil = 0

	if record.seatObject then
		record.seatObject:Sit(nil :: any)
		record.seatObject = nil
		record.lastRestTime = workspace:GetServerTimeNow()
		record.seatedAt = 0
	end
	
	if record.humanoid.Sit then
		record.humanoid.Sit = false
	end

	record.targetNode = node
	record.moveTargetPos = NodeGraph.GetMovementTargetPosition(node, NPCConfig.NODE_SPREAD_RADIUS, _nodesFolder)
	Local.ComputePath(record)
	Local.RequestPrefetch(record, node)
end

-- [[ Private Functions — Seamless leg prefetching ]] --
function Local.RequestPrefetch(record: NPCRecord, forNode: BasePart)
	local nodeType = NodeGraph.GetNodeType(forNode)
	if nodeType == "seatnode" or nodeType == "linenode" then return end

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

	record.actor:SendMessage("Decide", {
		npc = record.model,
		nodesFolder = _nodesFolder,
		currentNode = forNode,
		lastNode = record.currentNode,
		arrivedViaLink = willArriveViaLink,
		behaviorType = record.model:GetAttribute("BehaviorType") or "Linear",
		lastRestTime = record.lastRestTime,
		prefetch = true,
	})
end

function Local.OnPrefetchDecided(record: NPCRecord, nextNode: BasePart?, state: string)
	local prefetch = record.prefetch
	if not prefetch or not prefetch.awaitingDecision then return end -- superseded/stale — drop it

	prefetch.awaitingDecision = false
	prefetch.nextNode = nextNode
	prefetch.state = state

	if not nextNode then
		prefetch.ready = true -- dead end/queueing — nothing to path to
		return
	end

	local originPos = NodeGraph.GetNodePosition(prefetch.forNode)
	local goalPos = NodeGraph.GetMovementTargetPosition(nextNode, NPCConfig.NODE_SPREAD_RADIUS, _nodesFolder)
	prefetch.moveTargetPos = goalPos

	if (goalPos - originPos).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
		prefetch.alreadyThere = true
		prefetch.ready = true
		return
	end

	local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)
	local computeOk = pcall(function()
		path:ComputeAsync(originPos, goalPos)
	end)

	if computeOk and path.Status == Enum.PathStatus.Success then
		prefetch.waypoints = path:GetWaypoints()
		prefetch.path = path
	else
		prefetch.waypoints = nil -- falls back to a direct move at consume time
	end

	prefetch.ready = true
end

function Local.ConsumePrefetch(record: NPCRecord, prefetch: Prefetch)
	local nextNode = prefetch.nextNode
	record.model:SetAttribute("AIState", prefetch.state)

	if not nextNode then return end

	if record.seatObject then
		-- Shouldn't normally happen (RequestPrefetch skips Seat Node
		-- destinations) — kept as a safety net.
		record.seatObject:Sit(nil :: any)
		record.seatObject = nil
		record.lastRestTime = workspace:GetServerTimeNow()
		record.seatedAt = 0
	end

	if prefetch.alreadyThere then
		Local.OnArrive(record, nextNode)
		return
	end

	record.targetNode = nextNode
	record.moveTargetPos = prefetch.moveTargetPos

	-- Prefetched waypoints assume forNode's canonical position as the start —
	-- discard and repath if the NPC's real arrival drifted too far from that.
	local assumedOrigin = NodeGraph.GetNodePosition(prefetch.forNode)
	local drifted = (record.hrp.Position - assumedOrigin).Magnitude > NPCConfig.PREFETCH_DRIFT_TOLERANCE

	if prefetch.waypoints and not drifted then
		record.waypoints = prefetch.waypoints
		record.waypointIndex = if #prefetch.waypoints > 1 then 2 else 1
		if prefetch.path then
			record.pathBlockedConn = prefetch.path.Blocked:Connect(function(blockedWaypointIndex: number)
				Local.OnPathBlocked(record, blockedWaypointIndex)
			end)
		end
		Local.VisualizeWaypoints(record, prefetch.waypoints)
		Local.MoveToWaypoint(record)
	else
		if drifted then
			Local.DebugWarn(record, `prefetch drifted {math.floor((record.hrp.Position - assumedOrigin).Magnitude)} studs from assumed origin — recomputing fresh path instead of trusting stale waypoints`)
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
	if not node then return end

	local humanoid = record.humanoid
	local hrp = record.hrp
	if humanoid.Health <= 0 or not hrp.Parent then return end

	local goalPos = record.moveTargetPos or NodeGraph.GetNodePosition(node)
	local origin = hrp.Position

	if (goalPos - origin).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
		Local.OnArrive(record, node)
		return
	end

	Local.ClearPathBlockedConnection(record)

	local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)
	local computeOk = pcall(function()
		path:ComputeAsync(origin, goalPos)
	end)

	if computeOk and path.Status == Enum.PathStatus.Success then
		record.pendingRepath = false
		local computedWaypoints = path:GetWaypoints()
		record.waypoints = computedWaypoints
		-- Waypoint 1 is always ~the NPC's current position — start from 2.
		record.waypointIndex = if #computedWaypoints > 1 then 2 else 1
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
		-- Gate crossing: a straight-line direct move here just walks the NPC
		-- into the (still-solid) Gate Frame and gets it visibly stuck instead
		-- of actually passing through. Keep asking PathfindingService instead
		-- (retried from CheckStuck on the usual nudge-check cadence) until it
		-- finds a real route, or the stuck-timeout forces arrival as a last
		-- resort.
		Local.DebugWarn(record, `ComputeAsync failed crossing Platform->Depart to {node.Name} (computeOk={computeOk}, status={if computeOk then tostring(path.Status) else "n/a"}) — retrying pathfinding instead of falling back to direct move`)
		if not record.pendingRepath then
			record.pendingRepath = true
			Local.StartLeg(record, origin, goalPos)
		end
		return
	end

	record.pendingRepath = false
	Local.DebugWarn(record, `PathfindingService failed to {node.Name} (computeOk={computeOk}, status={if computeOk then tostring(path.Status) else "n/a"}) — falling back to direct move`)
	Local.MoveDirect(record, origin, goalPos)
end

function Local.ClearPathBlockedConnection(record: NPCRecord)
	if record.pathBlockedConn then
		record.pathBlockedConn:Disconnect()
		record.pathBlockedConn = nil
	end
end

function Local.OnPathBlocked(record: NPCRecord, blockedWaypointIndex: number)
	if not record.model.Parent then return end
	if not record.targetNode or not record.waypointIndex then return end
	if blockedWaypointIndex < record.waypointIndex then return end -- already past that point

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

function Local.MoveToWaypoint(record: NPCRecord)
	local waypoints = record.waypoints
	local index = record.waypointIndex
	if not waypoints or not index then return end

	local waypoint = waypoints[index]
	if not waypoint then
		if record.targetNode then Local.OnArrive(record, record.targetNode) end
		return
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		record.humanoid.Jump = true
	end

	Local.StartLeg(record, record.hrp.Position, waypoint.Position)
	record.humanoid:MoveTo(waypoint.Position)
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
	record.humanoid:MoveTo(goal)
	Local.DebugWarn(record, `MoveTo issued (direct) -> {goal} (WalkSpeed={record.humanoid.WalkSpeed}, currently at {record.hrp.Position})`)
end

function Local.CheckStuck(record: NPCRecord, goalPos: Vector3)
	local hrp = record.hrp
	local now = os.clock()
	local elapsed = now - record.moveStartedAt

	if elapsed <= record.legExpectedDuration * NPCConfig.LEG_TIMEOUT_GRACE_MULTIPLIER then
		return
	end

	if elapsed > NPCConfig.STUCK_TIMEOUT then
		Local.DebugWarn(record, `stuck-timeout toward {record.targetNode.Name} (still {math.floor((hrp.Position - goalPos).Magnitude)} studs away) — forcing arrival`)
		Local.OnArrive(record, record.targetNode :: BasePart)
		return
	end

	if now - record.lastProgressCheckAt < NPCConfig.STUCK_NUDGE_CHECK_INTERVAL then
		return
	end
	record.lastProgressCheckAt = now

	if record.pendingRepath then
		-- Gate-crossing leg with no route yet — keep asking PathfindingService
		-- instead of nudging into solid geometry (see ComputePath).
		Local.ComputePath(record)
		return
	end

	local moved = (hrp.Position - record.lastProgressPos).Magnitude
	local progressed = moved >= NPCConfig.STUCK_NUDGE_DISTANCE * NPCConfig.STUCK_PROGRESS_RATIO

	record.lastProgressPos = hrp.Position

	if progressed then
		-- Real (if slow) progress — likely just a detour or crowd slowdown,
		-- not actually stuck. Extend the budget instead of nudging.
		record.moveStartedAt = now
		record.legExpectedDuration = (goalPos - hrp.Position).Magnitude / math.max(record.humanoid.WalkSpeed, 1)
		return
	end

	local toGoal = goalPos - hrp.Position
	if toGoal.Magnitude < 0.05 then return end

	hrp.CFrame += toGoal.Unit * NPCConfig.STUCK_NUDGE_DISTANCE
	Local.DebugWarn(record, `no progress toward {record.targetNode.Name} — nudging {NPCConfig.STUCK_NUDGE_DISTANCE} studs toward goal`)
end

function Local.OnArrive(record: NPCRecord, node: BasePart)
	record.lastNode = record.currentNode
	record.currentNode = node
	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil
	record.moveStartedAt = 0
	record.pendingRepath = false
	Local.ClearWaypointMarkers(record)
	Local.ClearPathBlockedConnection(record)

	local previousLink = record.lastNode and NodeGraph.GetLink(record.lastNode)
	record.arrivedViaLink = previousLink ~= nil and previousLink == node

	local isSeatNode = NodeGraph.GetNodeType(node) == "seatnode"
	if isSeatNode then
		record.seatedAt = workspace:GetServerTimeNow()
		NodeGraph.ReleaseSeatReservation(node) -- Occupied (real Seat.Occupant) takes over as ground truth below

		local seatObject = NodeGraph.GetSeatObject(node)
		if seatObject then
			seatObject:Sit(record.humanoid)
			record.humanoid.Sit = true
			record.seatObject = seatObject
		end
	end

	if NodeGraph.GetNodeType(node) == "linenode" and not NodeGraph.IsSlotNode(node) then
		record.lineDwellUntil = workspace:GetServerTimeNow() + math.random(NPCConfig.LINE_DWELL_MIN, NPCConfig.LINE_DWELL_MAX)
	end

	-- The Depart Folder now holds multiple nodes chained by Link (gate
	-- entrance(s) -> ... -> final waiting/dwell node), so every one of them
	-- reports zone "Depart" — only the true end of that chain (no outgoing
	-- Link left) counts as "actually arrived," or the NPC would freeze the
	-- instant it touched the first gate node instead of walking the rest of
	-- the chain.
	local isFinalDepartNode = NodeGraph.GetZone(node, _nodesFolder :: Instance) == "Depart"
		and NodeGraph.GetLink(node) == nil

	if isFinalDepartNode then
		record.departArrivedAt = workspace:GetServerTimeNow()
	else
		record.departArrivedAt = 0
	end

	local prefetch = record.prefetch
	if prefetch and prefetch.forNode == node then
		if isSeatNode then
			record.prefetch = nil -- discard; must rest before leaving regardless of readiness
		elseif prefetch.ready then
			record.prefetch = nil
			Local.ConsumePrefetch(record, prefetch)
		end
	end
end

function Local.CheckWaypointProgress(record: NPCRecord)
	if not record.targetNode then return end

	local hrp = record.hrp
	if not hrp.Parent then return end

	if record.waypoints and record.waypointIndex then
		local waypoint = record.waypoints[record.waypointIndex]
		if not waypoint then return end

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

	-- Direct-line fallback leg (no navmesh route was found for this move).
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

function Local.OnDecisionReported(npc: Model, nextNode: BasePart?, state: string, isPrefetch: boolean?)
	local record = Local.FindRecordByModel(npc)
	if not record then return end

	if isPrefetch then
		Local.OnPrefetchDecided(record, nextNode, state)
		return
	end

	record.awaitingDecision = false
	npc:SetAttribute("AIState", state)

	if nextNode then
		Local.WalkTo(record, nextNode)
	end
end

-- [[ Public Functions ]] --

function Shared.FindNPCById(uid: string?): Model?
	if not uid or uid == "" then return nil end

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

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	Local.DespawnAll()
end

return Shared
