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

-- No Decoys in this slice — every NPC this service tracks is Crowd-kind.
-- Kept as a named type (rather than a bare string) so ArrestService's
-- `kind == "Decoy"` comparison stays meaningful once Decoys return.
export type NPCKind = "Crowd"

-- A decision + path leg computed ahead of time, while the NPC is still
-- physically walking the PRIOR leg, so the transition from one node to the
-- next is instant instead of pausing on a fresh decision round-trip +
-- PathfindingService:ComputeAsync yield. `forNode` is the node this was
-- computed as if the NPC had already arrived at — only valid to consume once
-- the NPC actually reaches that exact node (see Local.OnArrive).
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
	arrivedViaLink: boolean,
	awaitingDecision: boolean,
	decisionRequestedAt: number,
	lastRestTime: number,
	seatedAt: number,
	seatObject: Seat?,
	lineDwellUntil: number,
	departArrivedAt: number,
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

-- Fan-in channel every Crowd NPC's brain Actor reports its decision back
-- through — firing a BindableEvent is one of the sanctioned ways to safely
-- cross from an Actor's parallel context back to the main/serial thread.
-- Movement itself (PathfindingService, Humanoid:MoveTo) deliberately stays
-- on the main thread rather than being called from inside the Actor —
-- mirrors this project's earlier NPCBrainScript design (see legacy/), which
-- found that direct Humanoid mutation from a parallel Actor context doesn't
-- reliably take effect even after task.synchronize().
Local.decisionReportEvent = Instance.new("BindableEvent")

--|| Constants
local NPC_FOLDER_NAME = "NPCs"
local DEBUG_MARKERS_FOLDER_NAME = "NPCDebugMarkers" -- TEMP: waypoint visualizer while debugging pathfinding

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude

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
			if not record.actor.Parent then continue end

			if record.targetNode then
				-- Driven every frame rather than waiting on the Humanoid's own
				-- MoveToFinished event — advances the instant the NPC is close
				-- enough to the current waypoint instead of waiting for
				-- Roblox's own "reached" detection (which can stall/never fire
				-- around corners), so movement flows waypoint-to-waypoint
				-- instead of visibly stopping at each one.
				Local.CheckWaypointProgress(record)

				if record.targetNode and os.clock() - record.moveStartedAt > NPCConfig.STUCK_TIMEOUT then
					Local.DebugWarn(record, `stuck-timeout toward {record.targetNode.Name} (still {math.floor((record.hrp.Position - (record.moveTargetPos or NodeGraph.GetNodePosition(record.targetNode))).Magnitude)} studs away) — forcing arrival`)
					Local.OnArrive(record, record.targetNode)
				end

				continue
			end

			if record.awaitingDecision then
				-- Safety net: a crashed/lost decision report (e.g. an error
				-- inside the Actor) would otherwise leave this flag stuck
				-- true forever, permanently freezing the NPC — nothing else
				-- would ever clear it.
				if os.clock() - record.decisionRequestedAt > NPCConfig.DECISION_TIMEOUT then
					Local.DebugWarn(record, "decision request timed out (no report received) — retrying")
					record.awaitingDecision = false
				else
					continue
				end
			end

			if not record.currentNode then
				Local.SnapToNearestNode(record)
				continue
			end

			-- Seamless continuation: normally Local.OnArrive consumes a ready
			-- prefetch the instant it fires (see there). This only catches the
			-- rare case where the leg that just finished was shorter than the
			-- prefetch's own decision+path computation — wait for it here
			-- instead of firing a duplicate normal decision request.
			if record.prefetch and record.prefetch.forNode == record.currentNode then
				if record.prefetch.ready then
					local prefetch = record.prefetch :: Prefetch
					record.prefetch = nil
					Local.ConsumePrefetch(record, prefetch)
				end
				continue
			end

			-- Seated at a Seat Node: hold still (no decision request at all)
			-- until SEAT_REST_DURATION has passed, so the NPC actually rests
			-- instead of standing back up the instant it sits down.
			if record.seatedAt > 0 and workspace:GetServerTimeNow() - record.seatedAt < NPCConfig.SEAT_REST_DURATION then
				continue
			end

			-- Lingering at the front Line Node: same hold-still gate as Seat Node rest.
			if record.lineDwellUntil > 0 and workspace:GetServerTimeNow() < record.lineDwellUntil then
				continue
			end

			-- Standing at the Depart Node (graph dead end): hold indefinitely,
			-- no decision request, until GateService opens boarding
			-- (Workspace.BoardingOpen) and a short dwell has passed, then
			-- despawn -- the NPC "boards the plane". Deferred a tick via
			-- task.defer since CleanupNPC mutates _activeNPCs, which this
			-- exact loop is currently iterating over.
			if record.departArrivedAt > 0 then
				if Workspace:GetAttribute("BoardingOpen")
					and workspace:GetServerTimeNow() - record.departArrivedAt >= NPCConfig.BOARD_DWELL then
					Local.DebugWarn(record, "boarding open -- boarding the plane")
					task.defer(Local.CleanupNPC, record.model)
				end
				continue
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

-- Nodes live in the persistent map, not recreated per round — clear any
-- Occupied/LineIsFull/EnRouteCount left over from a previous round (e.g. an
-- NPC despawned mid-queue) so a line can't start a new round already stuck
-- "full" or falsely crowded.
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

-- Live-mirrors each Seat Node's `Occupied` attribute off the real Seat's
-- Occupant (covers players sitting too, not just NPCs claiming it).
function Local.WatchSeats(nodesFolder: Instance)
	for _, node in NodeGraph.EnumerateAllNodes(nodesFolder) do
		if NodeGraph.GetNodeType(node) ~= "seatnode" then continue end

		NodeGraph.ReleaseSeatReservation(node) -- Reserved is our own bookkeeping, unlike Occupied — doesn't carry real truth across rounds
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

-- [[ Private Functions — Spawning ]] --
function Local.GetRigTemplate(): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local rig = assets and assets:FindFirstChild("Rig")
	if not rig or not rig:IsA("Model") then
		warn("[NpcService] ReplicatedStorage.Assets.Rig not found or not a Model")
		return nil
	end
	return rig
end

-- Matches SpawnService's `<ActiveMap>.Spawns.<TEAM_NAME>` convention — a
-- single BasePart zone named "NPC" inside the map's shared Spawns folder.
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

-- `ActorScript.server.luau` is a literal sibling file in this same folder —
-- Rojo's folder+init.luau convention makes it a real child Instance of this
-- Service, matching the reference's `script.Script:Clone()`.
function Local.GetActorScriptTemplate(): Script?
	local template = script:FindFirstChild("ActorScript")
	if not template or not template:IsA("Script") then
		warn("[NpcService] ActorScript template not found")
		return nil
	end
	return template :: Script
end

-- Builds the per-NPC "brain" — an Actor running a cloned ActorScript in
-- genuinely parallel Luau, computing only *decisions* (which node to walk to
-- next — see Behaviors/). The ReportEvent ObjectValue hands the Actor a
-- reference to the shared decisionReportEvent it fires results back
-- through; the Nodes folder is instead passed fresh in each "Decide"
-- message payload (Instance references pass through SendMessage fine),
-- since `require`-ing MapService from inside the Actor would get an
-- isolated copy with no active map set.
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

	-- Anchored parts silently block Humanoid:MoveTo() — force them off.
	-- Network ownership is pinned server-side unconditionally so NPCs can't
	-- drift to a nearby client's physics authority. Only the root part
	-- collides with the world — a blocky rig's individual limbs each having
	-- their own collision lets a leg catch a low object's edge and get
	-- physically shoved up onto it, regardless of any pathfinding setting.
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
		arrivedViaLink = false,
		awaitingDecision = false,
		decisionRequestedAt = 0,
		lastRestTime = 0,
		seatedAt = 0,
		seatObject = nil,
		lineDwellUntil = 0,
		departArrivedAt = 0,
		pathBlockedConn = nil,
		waypointMarkers = nil,
		prefetch = nil,
	}

	-- Waypoint progression is driven by Local.CheckWaypointProgress from the
	-- Heartbeat loop (per-frame distance check) rather than MoveToFinished —
	-- see the comment at that call site for why.
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

			-- Destroyed mid-walk toward a reserved-but-not-yet-sat seat —
			-- release it, or it'd stay falsely claimed for the rest of the round.
			if record.targetNode and NodeGraph.GetNodeType(record.targetNode) == "seatnode" then
				NodeGraph.ReleaseSeatReservation(record.targetNode)
			end

			-- Same for an in-flight line commitment — the EnRouteLine
			-- ObjectValue dies with the model, but that alone doesn't
			-- decrement the line's own EnRouteCount attribute.
			NodeGraph.SetEnRouteLine(model, nil)

			table.remove(_activeNPCs, i)
			break
		end
	end

	if model.Parent then
		model:Destroy()
	end
end

-- [[ Private Functions — Debug logging ]] --
-- TEMP: visualizes decisions/movement in the Output window while Linear is
-- being tested — remove/gate behind a config flag once confirmed working.
function Local.DebugWarn(record: NPCRecord, message: string)
	warn(`[NPC {record.uid}] {message}`)
end

-- TEMP: drops a small non-colliding marker at every computed waypoint so a
-- path can be visually inspected in the Studio viewport while debugging
-- pathfinding — remove once movement is confirmed reliable.
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
		marker.Position = waypoint.Position
		marker.Parent = folder
		table.insert(markers, marker)
	end

	record.waypointMarkers = markers
end

-- [[ Private Functions — Movement (main thread only — see InjectActor) ]] --
-- Node-to-node legs route through PathfindingService's navmesh rather than a
-- single straight-line raycast, so the NPC walks around corners/walls
-- instead of beelining into them. Falls back to a raycast-clipped direct
-- line only if no navmesh route exists, so movement fails soft, not hard.

function Local.SnapToNearestNode(record: NPCRecord)
	local allNodes = NodeGraph.EnumerateAllNodes(_nodesFolder :: Instance)
	Local.DebugWarn(record, `first tick — nodesFolder={(_nodesFolder :: Instance):GetFullName()}, {#allNodes} node(s) found in graph`)

	local best, bestDist = nil, math.huge
	for _, node in allNodes do
		local dist = (NodeGraph.GetNodePosition(node) - record.hrp.Position).Magnitude
		if dist < bestDist then
			bestDist = dist
			best = node
		end
	end

	if best then
		Local.DebugWarn(record, `nearest node is {best.Name} ({math.floor(bestDist)} studs away)`)
		Local.OnArrive(record, best)
	else
		Local.DebugWarn(record, "no nodes found at all — NPC will never move. Check the Nodes folder's zone-subfolder structure.")
	end
end

function Local.WalkTo(record: NPCRecord, node: BasePart)
	record.lineDwellUntil = 0

	if record.seatObject then
		record.seatObject:Sit(nil :: any)
		record.seatObject = nil
		record.lastRestTime = workspace:GetServerTimeNow()
		record.seatedAt = 0
	elseif record.humanoid.Sit then
		record.humanoid.Sit = false
	end

	record.targetNode = node
	record.moveTargetPos = NodeGraph.GetMovementTargetPosition(node, NPCConfig.NODE_SPREAD_RADIUS)
	record.moveStartedAt = os.clock()
	Local.ComputePath(record)
	Local.RequestPrefetch(record, node)
end

-- [[ Private Functions — Seamless leg prefetching ]] --
-- Kicks off the decision + path computation for the leg AFTER `forNode`
-- while the NPC is still physically walking toward `forNode`, so that by the
-- time it actually arrives (Local.OnArrive), the next leg can start
-- immediately instead of pausing on a fresh decision round-trip. Skipped for
-- Seat Node / Line Node destinations: a Seat Node requires an actual rest
-- (SEAT_REST_DURATION) before the NPC may leave, and a Line Node slot's
-- occupancy is claimed/released as a side effect of computing the decision
-- itself — prefetching would release/claim slots before the NPC has
-- physically arrived at them.
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
	local goalPos = NodeGraph.GetMovementTargetPosition(nextNode, NPCConfig.NODE_SPREAD_RADIUS)
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

-- Applies a ready Prefetch computed by Local.RequestPrefetch — the seamless
-- counterpart to Local.OnDecisionReported/Local.WalkTo, called once the NPC
-- physically reaches `prefetch.forNode` (see Local.OnArrive).
function Local.ConsumePrefetch(record: NPCRecord, prefetch: Prefetch)
	local nextNode = prefetch.nextNode
	Local.DebugWarn(record, `decision (prefetched): next={nextNode and nextNode.Name or "NONE"}, state={prefetch.state or "?"}`)
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
	record.moveStartedAt = os.clock()

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
		local computedWaypoints = path:GetWaypoints()
		record.waypoints = computedWaypoints
		-- Waypoint 1 is always ~the NPC's current position — start from 2.
		record.waypointIndex = if #computedWaypoints > 1 then 2 else 1
		record.pathBlockedConn = path.Blocked:Connect(function(blockedWaypointIndex: number)
			Local.OnPathBlocked(record, blockedWaypointIndex)
		end)
		Local.DebugWarn(record, `path computed to {node.Name} — {#computedWaypoints} waypoints`)
		Local.VisualizeWaypoints(record, computedWaypoints)
		Local.MoveToWaypoint(record)
	else
		record.waypoints = nil
		record.waypointIndex = nil
		Local.ClearWaypointMarkers(record)
		Local.DebugWarn(record, `PathfindingService failed to {node.Name} (computeOk={computeOk}, status={if computeOk then tostring(path.Status) else "n/a"}) — falling back to direct move`)
		Local.MoveDirect(record, origin, goalPos)
	end
end

function Local.ClearPathBlockedConnection(record: NPCRecord)
	if record.pathBlockedConn then
		record.pathBlockedConn:Disconnect()
		record.pathBlockedConn = nil
	end
end

-- Reroutes the remaining leg only once Roblox reports it's actually
-- obstructed, instead of polling PathfindingService every frame.
function Local.OnPathBlocked(record: NPCRecord, blockedWaypointIndex: number)
	if not record.model.Parent then return end
	if not record.targetNode or not record.waypointIndex then return end
	if blockedWaypointIndex < record.waypointIndex then return end -- already past that point

	Local.DebugWarn(record, `path blocked at waypoint {blockedWaypointIndex} — recomputing`)
	Local.ComputePath(record)
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

	record.humanoid:MoveTo(waypoint.Position)
	Local.DebugWarn(record, `MoveTo issued -> waypoint {index}/{#waypoints} at {waypoint.Position} (WalkSpeed={record.humanoid.WalkSpeed}, currently at {record.hrp.Position})`)
end

-- Straight-line, raycast-clipped movement — only used when PathfindingService
-- can't find a navmesh route between the two nodes.
function Local.MoveDirect(record: NPCRecord, origin: Vector3, goalPos: Vector3)
	local toGoal = goalPos - origin

	RAYCAST_PARAMS.FilterDescendantsInstances = { record.model, _npcsFolder :: Instance }
	local result = Workspace:Raycast(origin, toGoal, RAYCAST_PARAMS)

	local goal = goalPos
	if result then
		local direction = toGoal.Unit
		local shortPos = result.Position - direction * NPCConfig.OBSTRUCTION_BUFFER

		-- Don't let the buffer push the goal behind the NPC if the
		-- obstruction is already closer than the buffer distance.
		goal = if (shortPos - origin):Dot(direction) > 0 then shortPos else origin
		Local.DebugWarn(record, `direct move obstructed by {result.Instance:GetFullName()} — clipping short`)
	end

	record.humanoid:MoveTo(goal)
	Local.DebugWarn(record, `MoveTo issued (direct) -> {goal} (WalkSpeed={record.humanoid.WalkSpeed}, currently at {record.hrp.Position})`)
end

function Local.OnArrive(record: NPCRecord, node: BasePart)
	record.lastNode = record.currentNode
	record.currentNode = node
	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil
	record.moveStartedAt = 0
	Local.ClearWaypointMarkers(record)
	Local.ClearPathBlockedConnection(record)

	-- Was this arrival a deterministic Link hop, as opposed to an Auto-mode
	-- pick? Used by NodeGraph.FindNearestNode to avoid immediately routing
	-- back into whatever Linked us here.
	local previousLink = record.lastNode and NodeGraph.GetLink(record.lastNode)
	record.arrivedViaLink = previousLink ~= nil and previousLink == node

	Local.DebugWarn(record, `arrived at {node.Name} (zone {NodeGraph.GetZone(node, _nodesFolder :: Instance)}, type {NodeGraph.GetNodeType(node)})`)

	-- Seat Nodes: actually sit the NPC in its linked Seat instance (rather
	-- than just standing at the node's position) and stamp SeatedAt — the
	-- Heartbeat loop holds off requesting a new decision for this NPC until
	-- SEAT_REST_DURATION has passed (see Shared.Init), so it actually rests
	-- instead of standing back up the instant it sits down.
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

	-- Front Line Node (not a Slot Node): linger before advancing past it,
	-- same hold-still gate as Seat Node rest (see the Heartbeat loop).
	if NodeGraph.GetNodeType(node) == "linenode" and not NodeGraph.IsSlotNode(node) then
		record.lineDwellUntil = workspace:GetServerTimeNow() + math.random(NPCConfig.LINE_DWELL_MIN, NPCConfig.LINE_DWELL_MAX)
	end

	-- Depart Node: the graph's dead end. Stamp arrival time so the Heartbeat
	-- loop can hold the NPC here until GateService opens boarding, then
	-- despawn it ("board the plane") instead of leaving it stuck forever —
	-- see the departArrivedAt check in Shared.Init. Reset to 0 on every other
	-- arrival so this only ever applies while actually standing at Depart.
	record.departArrivedAt = if NodeGraph.GetZone(node, _nodesFolder :: Instance) == "Depart"
		then workspace:GetServerTimeNow()
		else 0

	-- Seamless continuation: consume a prefetch computed for this exact node
	-- while it was still being walked to (see Local.RequestPrefetch) instead
	-- of waiting on the Heartbeat loop to request a fresh decision. Discarded
	-- on Seat Node arrivals — RequestPrefetch never targets one, but a stray
	-- in-flight prefetch from before shouldn't be applied here regardless,
	-- since the NPC needs to actually rest first.
	local prefetch = record.prefetch
	if prefetch and prefetch.forNode == node then
		if isSeatNode then
			record.prefetch = nil -- discard; must rest before leaving regardless of readiness
		elseif prefetch.ready then
			record.prefetch = nil
			Local.ConsumePrefetch(record, prefetch)
		end
		-- else: still awaiting its decision/path — left in place; the
		-- Heartbeat loop picks it up once ready (see Shared.Init).
	end
end

-- Called every Heartbeat (not event-driven off MoveToFinished — see the
-- comment where this is invoked) while an NPC has an active targetNode.
-- Advances to the next waypoint (or arrives) the instant the NPC is close
-- enough, rather than waiting for the Humanoid's own "reached" signal.
function Local.CheckWaypointProgress(record: NPCRecord)
	if not record.targetNode then return end

	local hrp = record.hrp
	if not hrp.Parent then return end

	if record.waypoints and record.waypointIndex then
		local waypoint = record.waypoints[record.waypointIndex]

		if waypoint and (hrp.Position - waypoint.Position).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
			if record.waypointIndex == #record.waypoints then
				Local.OnArrive(record, record.targetNode)
			else
				record.waypointIndex += 1
				record.moveStartedAt = os.clock() -- reset stuck timer per-waypoint
				Local.MoveToWaypoint(record)
			end
		end
		return
	end

	-- Direct-line fallback leg (no navmesh route was found for this move).
	local goalPos = record.moveTargetPos or NodeGraph.GetNodePosition(record.targetNode :: BasePart)
	local distance = (hrp.Position - goalPos).Magnitude

	if distance <= NPCConfig.ARRIVAL_TOLERANCE then
		Local.OnArrive(record, record.targetNode :: BasePart)
	end
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
	Local.DebugWarn(record, `decision: next={nextNode and nextNode.Name or "NONE"}, state={state}`)
	npc:SetAttribute("AIState", state)

	if nextNode then
		Local.WalkTo(record, nextNode)
	elseif record.seatObject then
		Local.DebugWarn(record, `no next target found while seated at {record.currentNode and record.currentNode.Name or "?"} — will retry next tick`)
	end
end

-- [[ Public Functions ]] --

-- Soft-required by ArrestService/StealService the lazy way
-- (`script.Parent:FindFirstChild("NpcService")` + `pcall(require, ...)`) —
-- calling directly on the returned module (`require(NpcService)` returns
-- `Shared` itself, no `.Shared.` indirection).
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

-- Always "Crowd" — there are no Decoys in this slice. ArrestService's
-- `kind == "Decoy"` branch is simply never taken, so arresting any tracked
-- NPC correctly falls through to a false arrest.
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
