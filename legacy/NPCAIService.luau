--|| Services
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

--|| References
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)
local NPCNodes = require(ReplicatedStorage.Modules.Configs.NPCNodes)

local RoundService = require(script.Parent.RoundService)
local MapService = require(script.Parent.MapService)
local ItemService = require(script.Parent.ItemService)
local RagdollService = require(script.Parent.RagdollService)

--|| Types
export type AIState = "Commuting" | "Queueing" | "Seated" | "Wandering" | "Alert" | "Panicking" | "DecoyJailed"
export type NPCKind = "Crowd" | "Decoy"
type PrimaryTrait = NPCConfig.PrimaryTrait -- Crowd-kind only; Decoys never roll one
type ModifierTrait = NPCConfig.ModifierTrait

type GraphNode = {
	part: BasePart,
	nodeType: string, -- normalized key, e.g. "node" | "linenode" | "seatnode" | "conveyornode" | "interactionnode" | "standnode"
	link: BasePart?,
	attachment: Attachment?,
	goalWeight: number,
	location: string?, -- optional zone tag, e.g. "Lobby" | "Concourse" | "Platform" | "Cafe" | "Convenience" | "Souvenir"
}

type BeltBagInfo = {
	npcUID: string,
	startPos: Vector3,
	endPos: Vector3,
	startTime: number,
	travelTime: number,
	arrived: boolean,
}

export type NPCRecord = {
	model: Model,
	humanoid: Humanoid,
	hrp: BasePart,
	uid: string,
	kind: NPCKind,
	primaryTrait: PrimaryTrait?,
	modifiers: { [ModifierTrait]: boolean },
	brainActor: Actor?,
	state: AIState,
	previousState: AIState?,
	currentNode: BasePart?,
	targetNode: BasePart?,
	lastNode: BasePart?,
	arrivedViaLink: boolean, -- was currentNode reached via lastNode's deterministic Link? (backtrack prevention)
	moveStartedAt: number,
	moveTargetPos: Vector3?,
	waypoints: { PathWaypoint }?,
	waypointIndex: number?,
	stateData: { [string]: any },
	connections: { RBXScriptConnection },
}

--|| Variables
local _connections: { RBXScriptConnection } = {}
local _npcsFolder: Folder? = nil

local Local = {}
local Shared = {}

Local.graph = {} :: { [BasePart]: GraphNode }
Local.records = {} :: { [Model]: NPCRecord }
Local.nextUid = 0

-- Node-type shared bookkeeping (kept centrally rather than per-node-instance
-- since node behavior is mostly stateless-per-type — see NPCNodes/).
Local.lineQueues = {} :: { [BasePart]: { NPCRecord } }
Local.seatOccupancy = {} :: { [BasePart]: NPCRecord }
Local.beltBags = {} :: { [Model]: BeltBagInfo }

-- Generic single-occupant bookkeeping for Stand/Interaction nodes (Seat keeps
-- its own dedicated table above — this one exists so a single occupancy
-- check/search helper can treat all "one NPC at a time" node types uniformly).
Local.nodeOccupancy = {} :: { [BasePart]: NPCRecord }

-- Re-exposed on Local so node handlers (passed `Local` as their `npcService`
-- argument) can read tunables without a second require.
Local.Config = NPCConfig

-- Fan-in channel every Crowd NPC's brain Actor reports its decision back
-- through — firing a BindableEvent is one of the sanctioned ways to safely
-- cross from an Actor's parallel context back to the main/serial thread.
-- Created once at module load (not round-scoped) since it's just a
-- coordination channel, not per-round state.
Local.decisionReportEvent = Instance.new("BindableEvent")

--|| Constants
local NPC_FOLDER_NAME = "NPCs"

local MOVE_RAYCAST_PARAMS = RaycastParams.new()
MOVE_RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude

local LOS_RAYCAST_PARAMS = RaycastParams.new()
LOS_RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude

local PATH_AGENT_PARAMS = {
	AgentRadius = NPCConfig.PATH_AGENT_RADIUS,
	AgentHeight = NPCConfig.PATH_AGENT_HEIGHT,
	AgentCanJump = NPCConfig.PATH_AGENT_CAN_JUMP,
	WaypointSpacing = NPCConfig.PATH_WAYPOINT_SPACING,
}

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, RoundService.OnStateChange:Connect(Local.OnRoundStateChange))

	-- "Violence witnessed" trigger — covers player-on-NPC, NPC-on-NPC, and
	-- player-on-player ragdolls uniformly via the single unconditional signal.
	table.insert(_connections, RagdollService.OnRagdolled:Connect(function(rig: Model)
		Shared.ForcePanic(rig:GetPivot().Position, NPCConfig.PANIC_RADIUS, false)
	end))

	table.insert(_connections, Workspace:GetAttributeChangedSignal("BoardingOpen"):Connect(Local.OnBoardingOpenChanged))

	table.insert(_connections, Local.decisionReportEvent.Event:Connect(Local.OnDecisionReported))

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

	Local.BuildGraph()

	if next(Local.graph) == nil then
		warn("[NPCAIService] Node graph is empty (no NodesFolder / no nodes) — no NPCs will be spawned")
		return
	end

	local decoyCount = math.random(NPCConfig.MIN_DECOYS, NPCConfig.MAX_DECOYS)
	local crowdCount = math.max(0, NPCConfig.MAX_NPCS - decoyCount)

	for _ = 1, crowdCount do
		Local.SpawnNPC("Crowd")
	end

	for _ = 1, decoyCount do
		Local.SpawnNPC("Decoy")
	end
end

function Local.DespawnAll()
	for npc in Local.records do
		Local.CleanupRecord(npc)
	end
	table.clear(Local.records)
	table.clear(Local.graph)
	table.clear(Local.lineQueues)
	table.clear(Local.seatOccupancy)
	table.clear(Local.nodeOccupancy)

	-- Bags mid-transit on a conveyor belt live directly in Workspace (not
	-- under _npcsFolder), so they need their own cleanup pass or they'd leak
	-- across rounds.
	for bag in Local.beltBags do
		if bag.Parent then
			bag:Destroy()
		end
	end
	table.clear(Local.beltBags)

	if _npcsFolder then
		_npcsFolder:Destroy()
		_npcsFolder = nil
	end
end

-- [[ Private Functions — Node graph ]] --
function Local.BuildGraph()
	table.clear(Local.graph)

	local activeMap = MapService.GetActiveMap()
	if not activeMap then
		warn("[NPCAIService] No active map — cannot build node graph")
		return
	end

	local nodesFolder = activeMap:FindFirstChild("Nodes")
	if not nodesFolder then
		warn("[NPCAIService] Active map has no 'Nodes' Folder — NPCs will have nowhere to walk")
		return
	end

	for _, part in nodesFolder:GetChildren() do
		if part:IsA("BasePart") then
			Local.RegisterNode(part)
		end
	end

	-- Resolve Link ObjectValues now that every node in the folder is known.
	for _, graphNode in Local.graph do
		local linkValue = graphNode.part:FindFirstChild("Link")
		if linkValue and linkValue:IsA("ObjectValue") and linkValue.Value then
			local target = linkValue.Value
			if target:IsA("BasePart") and Local.graph[target] then
				graphNode.link = target
			else
				warn(`[NPCAIService] Node "{graphNode.part:GetFullName()}" has a Link pointing outside NodesFolder`)
			end
		end
	end
end

function Local.RegisterNode(part: BasePart)
	local key = part.Name:gsub(" ", ""):lower()
	local nodeType = NPCNodes.IsKnownType(key) and key or "node"

	local location = part:GetAttribute("Location")

	Local.graph[part] = {
		part = part,
		nodeType = nodeType,
		link = nil,
		attachment = part:FindFirstChildOfClass("Attachment"),
		goalWeight = part:GetAttribute("GoalWeight") or 0,
		location = typeof(location) == "string" and location ~= "" and location or nil,
	}
end

function Local.GetNodePosition(node: BasePart): Vector3
	local graphNode = Local.graph[node]
	if graphNode and graphNode.attachment then
		return graphNode.attachment.WorldPosition
	end
	return node.Position
end

-- A plain "Node" is just a general waypoint along the path, not a precise
-- mark — spread arrivals across a small area so a crowd doesn't all funnel
-- through the exact same point. Line/Seat/Conveyor/Interaction/Stand nodes
-- all need their canonical position exactly (queue spacing, seat alignment,
-- belt start/end, dwell placement), so only Basic ("node") gets jitter.
function Local.GetMovementTargetPosition(node: BasePart): Vector3
	local graphNode = Local.graph[node]
	local basePos = Local.GetNodePosition(node)

	if not graphNode or graphNode.nodeType ~= "node" then
		return basePos
	end

	local angle = math.random() * math.pi * 2
	local dist = math.random() * NPCConfig.NODE_SPREAD_RADIUS
	return basePos + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
end

-- Linked nodes always resolve to their authored Link. Auto nodes (and Linked
-- nodes whose Link target vanished) fall back to the nearest eligible node
-- with a clear line of sight, biased toward higher GoalWeight.
function Local.ResolveNextNode(node: BasePart, record: NPCRecord): BasePart?
	local graphNode = Local.graph[node]
	if not graphNode then return nil end

	if graphNode.link and Local.graph[graphNode.link] then
		return graphNode.link
	end

	return Local.FindNearestAutoNode(node, record)
end

function Local.FindNearestAutoNode(fromNode: BasePart, record: NPCRecord): BasePart?
	local originPos = Local.GetNodePosition(fromNode)
	local best: BasePart? = nil
	local bestScore = -math.huge

	for part, graphNode in Local.graph do
		if part == fromNode or part == record.lastNode then continue end

		-- If fromNode was itself reached via a deterministic Link (e.g. just
		-- exited a Line/Seat/Conveyor sequence), don't pick a candidate whose
		-- own Link points straight back at fromNode — Linked nodes are
		-- unconditional, so that candidate would force an immediate walk
		-- right back next hop, a backtrack the plain lastNode exclusion above
		-- can't catch since the candidate itself isn't lastNode.
		if record.arrivedViaLink and graphNode.link == fromNode then continue end

		local pos = Local.GetNodePosition(part)
		local distance = (pos - originPos).Magnitude
		if distance > NPCConfig.NODE_SEARCH_RADIUS then continue end
		if not Local.HasClearLine(originPos, pos, { record.model, _npcsFolder }) then continue end

		local score = graphNode.goalWeight - distance
		if score > bestScore then
			bestScore = score
			best = part
		end
	end

	return best
end

function Local.PickInitialNode(record: NPCRecord): BasePart?
	local originPos = record.hrp.Position
	local best, bestDist = nil, math.huge

	for part in Local.graph do
		local dist = (Local.GetNodePosition(part) - originPos).Magnitude
		if dist < bestDist then
			bestDist = dist
			best = part
		end
	end

	return best
end

-- Shared by node-obstruction movement and (later) contagion line-of-sight
-- checks — a single raycast helper so both mechanics stay consistent.
function Local.HasClearLine(fromPos: Vector3, toPos: Vector3, ignore: { Instance? }): boolean
	local direction = toPos - fromPos
	if direction.Magnitude < 0.05 then return true end

	LOS_RAYCAST_PARAMS.FilterDescendantsInstances = ignore :: { Instance }
	local result = Workspace:Raycast(fromPos, direction, LOS_RAYCAST_PARAMS)
	return result == nil
end

-- Occupancy check spanning both Seat's dedicated table and the generic
-- Stand/Interaction table, so search/availability logic doesn't need to know
-- which table a given node type actually lives in.
function Local.IsNodeOccupied(node: BasePart): boolean
	return Local.seatOccupancy[node] ~= nil or Local.nodeOccupancy[node] ~= nil
end

-- Mirrors occupancy onto the node's `Occupied` attribute (per the authoring
-- convention) for Stand/Interaction nodes. Seat keeps its own bookkeeping in
-- Local.seatOccupancy but calls this too, purely so the attribute stays
-- accurate for anyone inspecting the node in Studio.
function Local.SetNodeOccupied(node: BasePart, occupied: boolean)
	node:SetAttribute("Occupied", occupied)
end

type NodeSearchOptions = {
	nodeType: string?,
	location: string?,
	availableOnly: boolean?,
	requireLOS: boolean?,
	radius: number?,
	exclude: { BasePart? }?,
}

-- General-purpose nearest-node search used by trait behaviors (Weary seeking
-- a seat, Caffeinated seeking a Cafe node, Walk-In seeking a line, wander
-- picking a nearby Interaction node, etc.) — a filtered/parameterized sibling
-- of Local.FindNearestAutoNode, which stays dedicated to plain graph-advance.
function Local.FindNearestNodeOfType(fromPos: Vector3, options: NodeSearchOptions?): BasePart?
	local opts = options or {}
	local radius = opts.radius or NPCConfig.NODE_SEARCH_RADIUS
	local requireLOS = opts.requireLOS ~= false

	local excludeSet: { [BasePart]: boolean } = {}
	if opts.exclude then
		for _, part in opts.exclude do
			if part then excludeSet[part] = true end
		end
	end

	local best: BasePart? = nil
	local bestDist = math.huge

	for part, graphNode in Local.graph do
		if excludeSet[part] then continue end
		if opts.nodeType and graphNode.nodeType ~= opts.nodeType then continue end
		if opts.location and graphNode.location ~= opts.location then continue end
		if opts.availableOnly and Local.IsNodeOccupied(part) then continue end

		local pos = Local.GetNodePosition(part)
		local distance = (pos - fromPos).Magnitude
		if distance > radius then continue end
		if requireLOS and not Local.HasClearLine(fromPos, pos, { _npcsFolder }) then continue end

		if distance < bestDist then
			bestDist = distance
			best = part
		end
	end

	return best
end

-- [[ Private Functions — Spawning ]] --
function Local.GetRigTemplate(): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local rig = assets and assets:FindFirstChild("Rig")
	if not rig or not rig:IsA("Model") then
		warn("[NPCAIService] ReplicatedStorage.Assets.Rig not found or not a Model")
		return nil
	end
	return rig
end

function Local.GetBrainScriptTemplate(): Script?
	local brainFolder = ServerScriptService:FindFirstChild("NPCBrain")
	local brainScript = brainFolder and brainFolder:FindFirstChild("NPCBrainScript")
	if not brainScript or not brainScript:IsA("Script") then
		warn("[NPCAIService] ServerScriptService.NPCBrain.NPCBrainScript not found or not a Script")
		return nil
	end
	return brainScript
end

-- Builds the per-NPC "brain" — an Actor running a cloned NPCBrainScript in
-- genuinely parallel Luau, which computes trait decisions (see
-- RequestTraitDecision/OnDecisionReported) without ever touching an
-- Instance. The ReportEvent ObjectValue hands the Actor a reference to the
-- single shared decisionReportEvent it fires results back through — Actors
-- can't see NPCAIService's Lua state directly, only what's reachable via the
-- Instance tree.
function Local.CreateBrainActor(npc: Model): Actor?
	local template = Local.GetBrainScriptTemplate()
	if not template then return nil end

	local actor = Instance.new("Actor")
	actor.Name = "Brain"

	local reportEventValue = Instance.new("ObjectValue")
	reportEventValue.Name = "ReportEvent"
	reportEventValue.Value = Local.decisionReportEvent
	reportEventValue.Parent = actor

	local brainScript = template:Clone()
	brainScript.Parent = actor
	brainScript.Enabled = true

	actor.Parent = npc

	return actor
end

-- Matches SpawnService's `<ActiveMap>.Spawns.<TEAM_NAME>` convention
-- (SpawnService.luau's Local.GetSpawnsFolder/Shared.SpawnPlayer) — a single
-- BasePart zone named "NPC" inside the map's shared Spawns folder.
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

	warn("[NPCAIService] Active map has no Spawns.NPC part — falling back to a random node position")

	-- Fallback so NPCs never spawn at the world origin if Spawns.NPC hasn't
	-- been authored yet: drop them at a random known node instead.
	local nodeParts: { BasePart } = {}
	for part in Local.graph do
		table.insert(nodeParts, part)
	end

	if #nodeParts > 0 then
		return nodeParts[math.random(1, #nodeParts)].CFrame
	end

	return CFrame.new()
end

function Local.SpawnNPC(kind: NPCKind): Model?
	local template = Local.GetRigTemplate()
	if not template or not _npcsFolder then return nil end

	local npc = template:Clone()
	npc.Name = kind == "Decoy" and "Decoy" or "NPC"

	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local hrp = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		warn("[NPCAIService] Rig template is missing a Humanoid/HumanoidRootPart")
		npc:Destroy()
		return nil
	end

	humanoid.WalkSpeed = NPCConfig.WALK_SPEED + (math.random() * 2 - 1) * NPCConfig.WALK_SPEED_JITTER

	Local.nextUid += 1
	local uid = `NPC_{Local.nextUid}_{math.floor(workspace:GetServerTimeNow() * 1000)}`
	npc:SetAttribute("UID", uid)
	npc:SetAttribute("Kind", kind)

	-- Decoys keep their own bespoke divert behavior (MaybeDivertDecoy) rather
	-- than rolling any of these — see NPC-AI.md.
	local primaryTrait: PrimaryTrait? = nil
	local modifiers: { [ModifierTrait]: boolean } = {}
	if kind == "Crowd" then
		primaryTrait = Local.RollPrimaryTrait()
		modifiers = Local.RollModifiers()

		npc:SetAttribute("Trait", primaryTrait)

		local modifierNames = {}
		for name, enabled in modifiers do
			if enabled then table.insert(modifierNames, name) end
		end
		if #modifierNames > 0 then
			npc:SetAttribute("Modifiers", table.concat(modifierNames, ","))
		end
	end

	npc:PivotTo(Local.GetSpawnCFrame())
	npc.Parent = _npcsFolder

	local record: NPCRecord = {
		model = npc,
		humanoid = humanoid,
		hrp = hrp,
		uid = uid,
		kind = kind,
		primaryTrait = primaryTrait,
		modifiers = modifiers,
		brainActor = nil,
		state = "Commuting",
		previousState = nil,
		currentNode = nil,
		targetNode = nil,
		lastNode = nil,
		arrivedViaLink = false,
		moveStartedAt = 0,
		moveTargetPos = nil,
		waypoints = nil,
		waypointIndex = nil,
		stateData = {},
		connections = {},
	}

	Local.records[npc] = record

	table.insert(record.connections, humanoid.MoveToFinished:Connect(function(reached)
		Local.OnMoveToFinished(record, reached)
	end))

	table.insert(record.connections, npc.Destroying:Once(function()
		Local.CleanupRecord(npc)
	end))

	-- Only Crowd NPCs get a brain — Decoys stay on their existing simple,
	-- deterministic-feeling divert script (bait behavior is intentionally
	-- scripted, not randomized through the parallel trait system).
	if kind == "Crowd" then
		record.brainActor = Local.CreateBrainActor(npc)
	end

	Local.EquipStarterItem(record)
	Local.BeginCommuting(record)

	return npc
end

-- Crowd NPCs carry a plain bag (steal-target parity with StealService).
-- Decoys instead hold a contraband item directly so they read HasContraband
-- to a TSA scan, baiting an arrest without needing the bag-steal mechanic.
function Local.EquipStarterItem(record: NPCRecord)
	local itemName = record.kind == "Decoy" and NPCConfig.DECOY_BAIT_ITEM or NPCConfig.DEFAULT_BAG_ITEM
	local item = ItemService.SpawnItem(itemName, record.hrp.CFrame)
	if not item then return end

	if not ItemService.EquipNPCItem(record.model, item) then
		item:Destroy()
	end
end

function Local.CleanupRecord(npc: Model)
	local record = Local.records[npc]
	if not record then return end

	Local.LeaveLineQueue(record)
	Local.ReleaseSeat(record)
	Local.ReleaseDwell(record)

	for _, conn in record.connections do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(record.connections)

	Local.records[npc] = nil

	if npc.Parent then
		npc:Destroy()
	end
end

-- [[ Private Functions — Movement ]] --
-- Node-to-node legs are routed through PathfindingService's navmesh rather
-- than a single straight-line raycast — this is what actually lets NPCs walk
-- around corners/walls between nodes instead of beelining into them. Falls
-- back to the old raycast-clipped direct line only if no navmesh route exists
-- (e.g. missing NavMeshModifiers) so movement fails soft, not hard.
function Local.WalkTo(record: NPCRecord, node: BasePart)
	record.targetNode = node
	record.moveTargetPos = Local.GetMovementTargetPosition(node)
	record.moveStartedAt = workspace:GetServerTimeNow()
	Local.ComputePath(record)
end

function Local.ComputePath(record: NPCRecord)
	local node = record.targetNode
	if not node then return end

	local humanoid = record.humanoid
	local hrp = record.hrp
	if not humanoid or humanoid.Health <= 0 or not hrp or not hrp.Parent then return end

	local targetPos = record.moveTargetPos or Local.GetNodePosition(node)
	local origin = hrp.Position

	if (targetPos - origin).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
		Local.ArriveAtNode(record, node)
		return
	end

	local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)
	local computeOk = pcall(function()
		path:ComputeAsync(origin, targetPos)
	end)

	if computeOk and path.Status == Enum.PathStatus.Success then
		local waypoints = path:GetWaypoints()
		record.waypoints = waypoints
		-- Waypoint 1 is always ~the NPC's current position — start from 2.
		record.waypointIndex = if #waypoints > 1 then 2 else 1
		Local.MoveToWaypoint(record)
	else
		record.waypoints = nil
		record.waypointIndex = nil
		Local.MoveDirect(record, origin, targetPos)
	end
end

function Local.MoveToWaypoint(record: NPCRecord)
	local waypoints = record.waypoints
	local index = record.waypointIndex
	if not waypoints or not index then return end

	local waypoint = waypoints[index]
	if not waypoint then
		if record.targetNode then
			Local.ArriveAtNode(record, record.targetNode)
		end
		return
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		record.humanoid.Jump = true
	end

	record.humanoid:MoveTo(waypoint.Position)
end

-- Straight-line, raycast-clipped movement — only used when PathfindingService
-- can't find a navmesh route between the two nodes.
function Local.MoveDirect(record: NPCRecord, origin: Vector3, targetPos: Vector3)
	local toTarget = targetPos - origin

	MOVE_RAYCAST_PARAMS.FilterDescendantsInstances = { record.model, _npcsFolder :: Instance }
	local result = Workspace:Raycast(origin, toTarget, MOVE_RAYCAST_PARAMS)

	local goal = targetPos
	if result then
		local direction = toTarget.Unit
		local shortPos = result.Position - direction * NPCConfig.OBSTRUCTION_BUFFER

		-- Don't let the buffer push the goal behind the NPC if the obstruction
		-- is already closer than the buffer distance.
		if (shortPos - origin):Dot(direction) > 0 then
			goal = shortPos
		else
			goal = origin
		end
	end

	record.humanoid:MoveTo(goal)
end

function Local.OnMoveToFinished(record: NPCRecord, _reached: boolean)
	if not record.targetNode then return end
	if not record.model or not record.model.Parent then return end

	local hrp = record.hrp
	if not hrp or not hrp.Parent then return end

	if record.waypoints and record.waypointIndex then
		local waypoint = record.waypoints[record.waypointIndex]

		if waypoint and (hrp.Position - waypoint.Position).Magnitude <= NPCConfig.ARRIVAL_TOLERANCE then
			if record.waypointIndex == #record.waypoints then
				Local.ArriveAtNode(record, record.targetNode)
				return
			end

			record.waypointIndex += 1
			record.moveStartedAt = workspace:GetServerTimeNow() -- reset stuck timer per-waypoint
			Local.MoveToWaypoint(record)
			return
		end

		-- Didn't reach the expected waypoint (shoved off course, blocked by
		-- another NPC, etc.) — past STUCK_TIMEOUT, recompute the route fresh
		-- rather than retrying a possibly-invalidated path.
		if workspace:GetServerTimeNow() - record.moveStartedAt > NPCConfig.STUCK_TIMEOUT then
			Local.ComputePath(record)
			return
		end

		task.delay(0.5, function()
			if Local.records[record.model] ~= record then return end
			if record.targetNode then
				Local.MoveToWaypoint(record)
			end
		end)
		return
	end

	-- Direct-line fallback leg (no navmesh route was found for this move).
	local targetPos = record.moveTargetPos or Local.GetNodePosition(record.targetNode)
	local distance = (hrp.Position - targetPos).Magnitude

	if distance <= NPCConfig.ARRIVAL_TOLERANCE then
		Local.ArriveAtNode(record, record.targetNode)
		return
	end

	if workspace:GetServerTimeNow() - record.moveStartedAt > NPCConfig.STUCK_TIMEOUT then
		Local.ArriveAtNode(record, record.targetNode)
		return
	end

	task.delay(0.5, function()
		if Local.records[record.model] ~= record then return end
		if record.targetNode then
			Local.MoveDirect(record, record.hrp.Position, targetPos)
		end
	end)
end

function Local.ArriveAtNode(record: NPCRecord, node: BasePart)
	record.lastNode = record.currentNode
	record.currentNode = node
	record.targetNode = nil
	record.moveStartedAt = 0
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil

	-- Was this arrival a deterministic Link hop (record.lastNode's Link
	-- pointed straight at `node`), as opposed to an Auto-mode pick? Used by
	-- FindNearestAutoNode to avoid immediately routing back into whatever
	-- Linked us here — see the comment there for why that matters.
	local previousGraphNode = record.lastNode and Local.graph[record.lastNode]
	record.arrivedViaLink = previousGraphNode ~= nil and previousGraphNode.link == node

	-- Reclaim happens regardless of what type of node this is (usually a
	-- plain Basic exit node) — check it before dispatching to the node's own
	-- handler so a Conveyor's paired exit doesn't need to know about bags.
	if record.stateData.pendingBagNode == node then
		Local.TryReclaimBag(record)
	end

	if record.modifiers.Caffeinated then
		Local.UpdateCaffeineTracking(record, node)
	end

	local graphNode = Local.graph[node]
	if not graphNode then return end -- node vanished mid-round; nothing to do

	local handler = NPCNodes.GetHandler(graphNode.nodeType)
	if handler and handler.OnArrive then
		handler.OnArrive(node, record, Local)
	end
end

-- [[ Private Functions — State machine ]] --
function Local.SetState(record: NPCRecord, newState: AIState)
	if record.state == newState then return end
	record.previousState = record.state
	record.state = newState
	record.model:SetAttribute("AIState", newState)
end

-- Pulls an NPC out of a node-specific holding state (queue slot / seat)
-- before switching it into a reaction state (Alert/Panicking).
function Local.InterruptForReaction(record: NPCRecord)
	if record.stateData.lineNode then
		Local.LeaveLineQueue(record)
	end

	if record.stateData.seatNode then
		Local.ReleaseSeat(record)
		local humanoid = record.humanoid
		if humanoid and humanoid.Parent then
			humanoid.Sit = false
		end
	end

	Local.ReleaseDwell(record)
end

-- The single "proceed toward the goal" call every node handler resolves
-- through: Basic pass-through, Line release, Seat stand-up, Conveyor
-- pass-through, and Alert/Panic calm-down all funnel here. Crowd NPCs with a
-- brain Actor detour through an async trait-decision request first (see
-- RequestTraitDecision/OnDecisionReported); everything else — including any
-- Crowd NPC whose Actor failed to spawn — proceeds normally immediately.
function Local.AdvanceOrWait(record: NPCRecord, fromNode: BasePart)
	if record.kind == "Crowd" and record.primaryTrait and record.brainActor then
		Local.RequestTraitDecision(record, fromNode)
		return
	end

	Local.ProceedNormally(record, fromNode)
end

-- A dead end (no Link, no eligible Auto node) is treated as having reached
-- the boarding gate — board if boarding is open, otherwise start Wandering
-- nearby.
function Local.ProceedNormally(record: NPCRecord, fromNode: BasePart)
	if record.kind == "Decoy" then
		if record.stateData.diverting then
			-- Just arrived at (or near) the deposit zone from a divert —
			-- resume normal Commuting pathing from here.
			record.stateData.diverting = nil
		else
			local divertNode = Local.MaybeDivertDecoy(record)
			if divertNode then
				record.stateData.diverting = true
				Local.SetState(record, "Commuting")
				Local.WalkTo(record, divertNode)
				return
			end
		end
	end

	local nextNode = Local.ResolveNextNode(fromNode, record)

	if nextNode then
		Local.SetState(record, "Commuting")
		Local.WalkTo(record, nextNode)
		return
	end

	if Local.IsBoardingOpen() then
		Local.SetState(record, "Commuting")
	else
		Local.EnterWandering(record, fromNode)
	end
end

function Local.ResumeCommuting(record: NPCRecord)
	local fromNode = record.currentNode
	if fromNode then
		Local.AdvanceOrWait(record, fromNode)
	else
		Local.SetState(record, "Commuting")
	end
end

-- [[ Private Functions — Traits (Crowd-kind only) ]] --

function Local.RollPrimaryTrait(): PrimaryTrait
	local total = 0
	for _, entry in NPCConfig.PRIMARY_TRAIT_WEIGHTS do
		total += math.max(entry.weight, 0)
	end

	local roll = math.random() * total
	local cumulative = 0

	for _, entry in NPCConfig.PRIMARY_TRAIT_WEIGHTS do
		cumulative += math.max(entry.weight, 0)
		if roll <= cumulative then
			return entry.name
		end
	end

	return NPCConfig.PRIMARY_TRAIT_WEIGHTS[#NPCConfig.PRIMARY_TRAIT_WEIGHTS].name
end

-- Each Modifier is rolled independently, so an NPC can end up with none, one,
-- or all three stacked on top of its Primary.
function Local.RollModifiers(): { [ModifierTrait]: boolean }
	local modifiers: { [ModifierTrait]: boolean } = {}
	for name, chance in NPCConfig.MODIFIER_CHANCE do
		if math.random() < chance then
			modifiers[name] = true
		end
	end
	return modifiers
end

-- Picks the first node a freshly-spawned Crowd NPC walks toward, branching on
-- Primary: Loiterer never actually commutes (it self-schedules via
-- LoiterStep), Walk-In seeks the nearest Line Node ("buys a ticket" near
-- spawn) before falling back to the normal nearest-any-node pick everyone
-- else uses. This is a one-time spawn setup step, not a recurring AI
-- decision, so it stays synchronous on the main thread rather than round-
-- tripping through the brain Actor.
function Local.BeginCommuting(record: NPCRecord)
	if record.primaryTrait == "Loiterer" then
		Local.LoiterStep(record)
		return
	end

	local firstNode: BasePart? = nil
	if record.primaryTrait == "WalkIn" then
		firstNode = Local.FindNearestNodeOfType(record.hrp.Position, { nodeType = "linenode", requireLOS = false })
	end
	firstNode = firstNode or Local.PickInitialNode(record)

	if firstNode then
		Local.WalkTo(record, firstNode)
	end
end

-- Sends a decision request to the NPC's brain Actor and returns immediately
-- — the Actor computes which behavior category applies (in parallel Luau,
-- see NPCBrainScript) and reports back via Local.decisionReportEvent, which
-- OnDecisionReported picks up and actually executes (target resolution +
-- any Instance mutation happens only on the main thread, never in the
-- Actor). Cooldowns are consumed here at request time — whether or not the
-- Actor's roll actually hits — mirroring how the pre-Actor-split version
-- gated re-attempts so a modifier "in consideration" doesn't re-roll every
-- single node arrival regardless of outcome.
function Local.RequestTraitDecision(record: NPCRecord, fromNode: BasePart)
	local epoch = (record.stateData.decisionEpoch or 0) + 1
	record.stateData.decisionEpoch = epoch
	record.stateData.decisionFromNode = fromNode

	local now = workspace:GetServerTimeNow()
	local thiefReady = (record.stateData.thiefCooldownUntil or 0) <= now
	local caffeineReady = not record.stateData.caffeineBoosted and (record.stateData.caffeineCooldownUntil or 0) <= now

	if record.modifiers.Thief and thiefReady then
		record.stateData.thiefCooldownUntil = now + NPCConfig.THIEF_STEAL_COOLDOWN
	end
	if record.modifiers.Caffeinated and caffeineReady then
		record.stateData.caffeineCooldownUntil = now + NPCConfig.CAFFEINE_DIVERT_COOLDOWN
	end

	local restChance = record.modifiers.Weary and NPCConfig.WEARY_REST_CHANCE or NPCConfig.REST_CHANCE

	local request = {
		uid = record.uid,
		requestId = epoch,
		primaryTrait = record.primaryTrait,
		modifiers = record.modifiers,
		thiefReady = thiefReady,
		caffeineReady = caffeineReady,
		restChance = restChance,
		wanderChance = NPCConfig.WANDER_CHANCE,
		thiefChance = NPCConfig.THIEF_STEAL_CHANCE,
		caffeineChance = NPCConfig.CAFFEINE_DIVERT_CHANCE,
	}

	(record.brainActor :: Actor):SendMessage("Decide", request)

	-- Safety net: if the Actor never responds (script error, message lost),
	-- don't leave the NPC frozen forever. Invalidates the epoch so a late
	-- real response arriving after this fires is correctly ignored instead
	-- of double-executing a decision.
	task.delay(NPCConfig.DECISION_TIMEOUT, function()
		if Local.records[record.model] ~= record then return end
		if record.stateData.decisionEpoch ~= epoch then return end
		record.stateData.decisionEpoch = -1
		Local.ProceedNormally(record, fromNode)
	end)
end

-- Fired by every Crowd NPC's brain Actor once it's decided. Resolves the
-- specific target (seat/cafe-node/victim, using the caches only the main
-- thread has access to) and executes the mutation.
function Local.OnDecisionReported(uid: string, requestId: number, action: string)
	local record = Local.FindRecordById(uid)
	if not record then return end
	if record.stateData.decisionEpoch ~= requestId then return end -- stale/superseded
	if record.state ~= "Commuting" then return end -- interrupted (Alert/Panic/etc.) while awaiting

	local fromNode = record.stateData.decisionFromNode
	if not fromNode then return end

	if action == "Loiter" then
		Local.LoiterStep(record)
	elseif action == "Theft" then
		local victim = Local.FindTheftVictim(record)
		if victim then
			Local.StartTheft(record, victim, fromNode)
		else
			Local.ProceedNormally(record, fromNode)
		end
	elseif action == "CafeDivert" then
		local cafeNode = Local.FindNearestNodeOfType(record.hrp.Position, { location = "Cafe", exclude = { fromNode } })
		if cafeNode then
			Local.SetState(record, "Commuting")
			Local.WalkTo(record, cafeNode)
		else
			Local.ProceedNormally(record, fromNode)
		end
	elseif action == "Rest" then
		local epoch = (record.stateData.restEpoch or 0) + 1
		record.stateData.restEpoch = epoch
		Local.TryRest(record, fromNode, workspace:GetServerTimeNow() + NPCConfig.REST_SEARCH_TIMEOUT, epoch)
	elseif action == "Wander" then
		Local.LocalWanderStep(record, fromNode)
	else
		Local.ProceedNormally(record, fromNode)
	end
end

-- [[ Private Functions — Line Impatience (all queued Crowd NPCs) ]] --

-- Hooked from Local.JoinLineQueue for every Crowd NPC that joins a queue.
-- Ticks an accumulating Impatience meter (only while behind the front — once
-- it's your turn you're being served, not waiting) at
-- IMPATIENCE_ROLL_INTERVAL; once it crosses IMPATIENCE_THRESHOLD the NPC
-- gives up on the line. Token-guarded (mirrors EnterPanic's panicEpoch) so
-- joining a second line later in the round (e.g. the conveyor checkpoint,
-- after the ticket line) can't leave a stale meter still ticking alongside a
-- fresh one.
function Local.TickImpatience(record: NPCRecord, epoch: number)
	if Local.records[record.model] ~= record then return end
	if record.kind ~= "Crowd" then return end
	if record.stateData.impatienceEpoch ~= epoch then return end
	if record.state ~= "Queueing" or not record.stateData.lineNode then return end

	if (record.stateData.slotIndex or 1) > 1 then
		local multiplier = (record.primaryTrait and NPCConfig.IMPATIENCE_PRIMARY_MULTIPLIER[record.primaryTrait] or 1)
			+ (record.modifiers.Weary and NPCConfig.IMPATIENCE_WEARY_BONUS or 0)
		record.stateData.impatience = (record.stateData.impatience or 0) + multiplier

		if record.stateData.impatience >= NPCConfig.IMPATIENCE_THRESHOLD then
			Local.GiveUpOnLine(record)
			return
		end
	end

	task.delay(NPCConfig.IMPATIENCE_ROLL_INTERVAL, function()
		Local.TickImpatience(record, epoch)
	end)
end

-- "If [impatience is] met they just go to seat or leave the airport" — pulls
-- the NPC out of the queue, then rolls between the two outcomes.
function Local.GiveUpOnLine(record: NPCRecord)
	local fromNode = record.currentNode or (record.stateData.lineNode :: BasePart?)
	Local.LeaveLineQueue(record)
	record.stateData.impatience = nil

	if fromNode and math.random() < NPCConfig.IMPATIENCE_SEAT_CHANCE then
		Local.SetState(record, "Commuting")
		local epoch = (record.stateData.restEpoch or 0) + 1
		record.stateData.restEpoch = epoch
		Local.TryRest(record, fromNode, workspace:GetServerTimeNow() + NPCConfig.REST_SEARCH_TIMEOUT, epoch)
	else
		Local.LeaveAirport(record)
	end
end

-- Pulls the NPC out of whatever it's doing and walks it back toward the
-- spawn zone, destroying it on arrival (or after MoveToFinished gives up) —
-- "disregards waiting in line and just goes back to the spawn part and
-- leaves the airport," per spec. Bypasses the node graph entirely since this
-- is a one-off cosmetic exit, not a real commute leg.
function Local.LeaveAirport(record: NPCRecord)
	Local.InterruptForReaction(record)
	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil

	local zone = Local.GetSpawnZone()
	local destination = zone and Local.GetRandomPositionInPart(zone) or record.hrp.Position
	record.humanoid:MoveTo(destination)

	local connection: RBXScriptConnection
	connection = record.humanoid.MoveToFinished:Connect(function()
		connection:Disconnect()
		if Local.records[record.model] ~= record then return end
		Local.CleanupRecord(record.model)
	end)
	table.insert(record.connections, connection)
end

-- [[ Private Functions — Rest / Wander (shared default flow) ]] --

-- Retries a few times over REST_SEARCH_TIMEOUT looking for a free seat
-- (seats can free up between attempts) before giving up and resuming normal
-- advancement, per spec ("if no seat is available after Xs then proceed").
-- Token-guarded (mirrors EnterPanic's panicEpoch) so an Alert/Panic interrupt
-- followed by a resume can't leave a stale retry chain racing a fresh one.
function Local.TryRest(record: NPCRecord, fromNode: BasePart, deadline: number, epoch: number)
	if Local.records[record.model] ~= record then return end
	if record.stateData.restEpoch ~= epoch then return end
	if record.state ~= "Commuting" then return end -- interrupted elsewhere (Alert/Panic/etc.)

	local seat = Local.FindNearestNodeOfType(record.hrp.Position, {
		nodeType = "seatnode",
		availableOnly = true,
		exclude = { fromNode },
		radius = NPCConfig.NODE_SEARCH_RADIUS,
	})

	if seat then
		Local.WalkTo(record, seat)
		return
	end

	if workspace:GetServerTimeNow() >= deadline then
		Local.AdvanceOrWait(record, fromNode)
		return
	end

	task.delay(1, function()
		Local.TryRest(record, fromNode, deadline, epoch)
	end)
end

-- Rolled if Resting didn't trigger: chance to detour into a nearby
-- Interaction node, else a brief local wander near the current position
-- before resuming toward the next node.
function Local.LocalWanderStep(record: NPCRecord, fromNode: BasePart)
	if math.random() < NPCConfig.WANDER_INTERACT_CHANCE then
		local interactionNode = Local.FindNearestNodeOfType(record.hrp.Position, {
			nodeType = "interactionnode",
			availableOnly = true,
			exclude = { fromNode },
			radius = NPCConfig.LOCAL_WANDER_RADIUS,
		})

		if interactionNode then
			Local.WalkTo(record, interactionNode)
			return
		end
	end

	local anchor = record.hrp.Position
	local angle = math.random() * math.pi * 2
	local dist = math.random() * NPCConfig.LOCAL_WANDER_RADIUS
	local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil
	record.humanoid:MoveTo(anchor + offset)

	task.delay(math.random(2, 4), function()
		if Local.records[record.model] ~= record then return end
		if record.state ~= "Commuting" then return end
		Local.AdvanceOrWait(record, fromNode)
	end)
end

-- [[ Private Functions — Loiterer (perpetual local wander, never boards) ]] --

-- Picks a random reachable node near the NPC's current position and walks
-- there — unlike normal commuting this never resolves "toward the boarding
-- gate," so a Loiterer just drifts around the airport indefinitely. If it
-- happens to wander into a Line/Seat/Conveyor/Interaction node it still goes
-- through that node's normal behavior (a Loiterer can incidentally sit or
-- queue), but every AdvanceOrWait call routes back here via the trait hook.
function Local.LoiterStep(record: NPCRecord)
	if Local.records[record.model] ~= record then return end
	if record.primaryTrait ~= "Loiterer" then return end

	local originPos = record.hrp.Position
	local candidates: { BasePart } = {}

	for part in Local.graph do
		if part == record.lastNode then continue end
		local pos = Local.GetNodePosition(part)
		if (pos - originPos).Magnitude > NPCConfig.NODE_SEARCH_RADIUS then continue end
		if not Local.HasClearLine(originPos, pos, { record.model, _npcsFolder }) then continue end
		table.insert(candidates, part)
	end

	if #candidates > 0 then
		Local.SetState(record, "Commuting")
		Local.WalkTo(record, candidates[math.random(1, #candidates)])
		return
	end

	-- Nothing reachable right now — try again shortly rather than stalling.
	task.delay(2, function()
		Local.LoiterStep(record)
	end)
end

-- [[ Private Functions — Caffeinated (Cafe divert + post-cafe boost) ]] --

-- Called from Local.ArriveAtNode for every Caffeinated NPC. Tracks whether
-- it's currently inside the Cafe zone and applies a one-time permanent speed
-- + alert-sensitivity boost the moment it arrives somewhere outside the Cafe
-- zone after having been in it.
function Local.UpdateCaffeineTracking(record: NPCRecord, node: BasePart)
	local graphNode = Local.graph[node]
	local isCafe = graphNode ~= nil and graphNode.location == "Cafe"

	if isCafe then
		record.stateData.wasInCafe = true
		return
	end

	if record.stateData.wasInCafe and not record.stateData.caffeineBoosted then
		record.stateData.caffeineBoosted = true
		record.humanoid.WalkSpeed *= NPCConfig.CAFFEINE_SPEED_MULTIPLIER
		record.stateData.alertEscalateChanceOverride = NPCConfig.CAFFEINE_ALERT_ESCALATE_CHANCE
	end

	record.stateData.wasInCafe = nil
end

-- [[ Private Functions — Thief (NPC-vs-NPC theft) ]] --

function Local.FindTheftVictim(record: NPCRecord): NPCRecord?
	local originPos = record.hrp.Position
	local best: NPCRecord? = nil
	local bestDist = math.huge

	for _, other in Local.records do
		if other == record then continue end
		if other.kind ~= "Crowd" then continue end
		if other.state == "DecoyJailed" then continue end
		if other.stateData.beingRobbed then continue end

		local heldItem = other.model:GetAttribute("HeldItem")
		if not heldItem or heldItem == "" then continue end

		local otherPos = other.hrp.Position
		local distance = (otherPos - originPos).Magnitude
		if distance > NPCConfig.THIEF_STEAL_RANGE then continue end
		if not Local.HasClearLine(originPos, otherPos, { record.model, other.model, _npcsFolder }) then continue end

		if distance < bestDist then
			bestDist = distance
			best = other
		end
	end

	return best
end

function Local.StartTheft(thief: NPCRecord, victim: NPCRecord, fromNode: BasePart)
	victim.stateData.beingRobbed = true

	thief.targetNode = nil
	thief.waypoints = nil
	thief.waypointIndex = nil
	thief.humanoid:MoveTo(victim.hrp.Position)

	local epoch = (thief.stateData.theftEpoch or 0) + 1
	thief.stateData.theftEpoch = epoch

	task.delay(NPCConfig.THIEF_APPROACH_DURATION, function()
		Local.ResolveTheft(thief, victim, epoch, fromNode)
	end)
end

function Local.ResolveTheft(thief: NPCRecord, victim: NPCRecord, epoch: number, fromNode: BasePart)
	if Local.records[victim.model] == victim then
		victim.stateData.beingRobbed = nil
	end

	if Local.records[thief.model] ~= thief or thief.stateData.theftEpoch ~= epoch then
		return -- superseded by a newer theft, or the thief is gone
	end

	if thief.state ~= "Commuting" then
		-- Thief got Alerted/Panicked/etc. mid-approach — abandon the attempt,
		-- whatever interrupted it already owns its movement now.
		return
	end

	if Local.records[victim.model] == victim then
		local distance = (thief.hrp.Position - victim.hrp.Position).Magnitude
		if distance <= NPCConfig.THIEF_STEAL_RANGE then
			local stolen = ItemService.ForceDropItem(victim.model)
			if stolen then
				if ItemService.EquipNPCItem(thief.model, stolen) then
					Shared.ForceAlert(victim.model)
				else
					stolen:Destroy()
				end
			end
		end
	end

	Local.AdvanceOrWait(thief, fromNode)
end

-- [[ Private Functions — Waiting / Wandering (boarding-gate gating) ]] --
function Local.IsBoardingOpen(): boolean
	local value = Workspace:GetAttribute("BoardingOpen")
	if value == nil then return true end -- undecided/not-yet-built Airplane cycle defaults to open
	return value == true
end

function Local.OnBoardingOpenChanged()
	if not Local.IsBoardingOpen() then return end

	for _, record in Local.records do
		if record.state == "Wandering" then
			Local.ResumeCommuting(record)
		end
	end
end

function Local.EnterWandering(record: NPCRecord, gateNode: BasePart)
	Local.SetState(record, "Wandering")
	record.stateData.wanderGateNode = gateNode
	Local.WanderStep(record)
end

function Local.WanderStep(record: NPCRecord)
	if record.state ~= "Wandering" then return end

	local gateNode = record.stateData.wanderGateNode :: BasePart?
	local basePos = gateNode and Local.GetNodePosition(gateNode) or record.hrp.Position

	local angle = math.random() * math.pi * 2
	local dist = math.random() * NPCConfig.WANDER_RADIUS
	local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

	record.humanoid:MoveTo(basePos + offset)

	local interval = math.random(NPCConfig.WANDER_INTERVAL_MIN, NPCConfig.WANDER_INTERVAL_MAX)
	task.delay(interval, function()
		if Local.records[record.model] ~= record then return end
		Local.WanderStep(record)
	end)
end

-- [[ Private Functions — Alert / Panic / Contagion ]] --
function Local.EnterAlert(record: NPCRecord)
	if record.state == "Panicking" or record.state == "DecoyJailed" or record.state == "Alert" then return end

	Local.InterruptForReaction(record)
	Local.SetState(record, "Alert")
	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil
	record.humanoid:MoveTo(record.hrp.Position) -- pause in place to "look"

	task.delay(NPCConfig.ALERT_LOOK_DURATION, function()
		if Local.records[record.model] ~= record then return end
		if record.state ~= "Alert" then return end

		local escalateChance = record.stateData.alertEscalateChanceOverride or NPCConfig.ALERT_ESCALATE_CHANCE
		if math.random() < escalateChance then
			Local.EnterPanic(record)
		else
			Local.ResumeCommuting(record)
		end
	end)
end

function Local.EnterPanic(record: NPCRecord)
	if record.state == "DecoyJailed" then return end

	if record.state ~= "Panicking" then
		Local.InterruptForReaction(record)
		Local.SetState(record, "Panicking")
		Local.PropagateContagion(record)
	end

	Local.WanderErratically(record)

	-- Token pattern (mirrors RoundService's _stateId) so an NPC re-triggered
	-- into Panic while already panicking extends the duration correctly —
	-- only the most-recently-scheduled timer is allowed to actually resume.
	local epoch = (record.stateData.panicEpoch or 0) + 1
	record.stateData.panicEpoch = epoch

	task.delay(NPCConfig.PANIC_DURATION, function()
		if Local.records[record.model] ~= record then return end
		if record.state ~= "Panicking" then return end
		if record.stateData.panicEpoch ~= epoch then return end
		Local.ResumeCommuting(record)
	end)
end

function Local.WanderErratically(record: NPCRecord)
	if record.state ~= "Panicking" then return end

	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil

	local origin = record.hrp.Position
	local angle = math.random() * math.pi * 2
	local dist = math.random() * NPCConfig.PANIC_RADIUS
	local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

	record.humanoid:MoveTo(origin + offset)

	task.delay(math.random(1, 2), function()
		if Local.records[record.model] ~= record then return end
		Local.WanderErratically(record)
	end)
end

-- Radius + raycast line-of-sight gated, per the confirmed contagion rule.
-- Spreads from the panicking NPC's own position, not the original trigger,
-- so repeated propagation produces an outward wave rather than a fixed blast.
function Local.PropagateContagion(source: NPCRecord)
	local originPos = source.hrp.Position

	for _, other in Local.records do
		if other == source then continue end
		if other.state == "Panicking" or other.state == "DecoyJailed" then continue end

		local otherPos = other.hrp.Position
		if (otherPos - originPos).Magnitude > NPCConfig.PANIC_RADIUS then continue end
		if not Local.HasClearLine(originPos, otherPos, { _npcsFolder }) then continue end

		if math.random() < NPCConfig.CONTAGION_CHANCE then
			Local.EnterPanic(other)
		end
	end
end

-- [[ Private Functions — Line node (FIFO queue) ]] --

-- Direction the line "faces": toward the node's Link if it has one (the
-- direction NPCs advance through the queue), else the part's own orientation.
function Local.GetLineForward(node: BasePart): Vector3
	local graphNode = Local.graph[node]
	if graphNode and graphNode.link then
		local forward = Local.GetNodePosition(graphNode.link) - Local.GetNodePosition(node)
		if forward.Magnitude > 0.01 then
			return forward.Unit
		end
	end
	return node.CFrame.LookVector
end

-- Slot 1 (front) always targets the node itself. Every other slot targets a
-- point SLOT_SPACING behind whoever is directly ahead of it in the queue —
-- literally "walk behind the last person in line" — rather than a fixed grid
-- computed purely from the node's position and an index. Recomputed whenever
-- AdvanceLine reindexes (anyone joining/leaving), which is the main thread's
-- one authoritative point of truth for queue membership/ordering.
function Local.GetLineSlotPosition(node: BasePart, slotIndex: number): Vector3
	local forward = Local.GetLineForward(node)

	if slotIndex > 1 then
		local queue = Local.lineQueues[node]
		local ahead = queue and queue[slotIndex - 1]
		local aheadHrp = ahead and ahead.hrp

		if aheadHrp and aheadHrp.Parent then
			return aheadHrp.Position - forward * NPCConfig.SLOT_SPACING
		end
	end

	-- Front of the line, or the NPC ahead is gone/not yet resolved — fall
	-- back to the node-relative grid position.
	local basePos = Local.GetNodePosition(node)
	return basePos - forward * (NPCConfig.SLOT_SPACING * (slotIndex - 1))
end

function Local.MoveToLineSlot(record: NPCRecord)
	local node = record.stateData.lineNode :: BasePart?
	local slotIndex = record.stateData.slotIndex :: number?
	if not node or not slotIndex then return end

	record.humanoid:MoveTo(Local.GetLineSlotPosition(node, slotIndex))
end

-- Reassigns every queued NPC's slot to match its current position in the
-- array (called after anyone joins/leaves) and kicks off the front-of-line
-- dwell timer once a new NPC becomes slot 1.
function Local.AdvanceLine(node: BasePart)
	local queue = Local.lineQueues[node]
	if not queue then return end

	for i, record in queue do
		record.stateData.slotIndex = i
		Local.MoveToLineSlot(record)

		if i == 1 and not record.stateData.dwellStarted then
			Local.StartLineDwell(node, record)
		end
	end
end

function Local.JoinLineQueue(node: BasePart, record: NPCRecord)
	local queue = Local.lineQueues[node]
	if not queue then
		queue = {}
		Local.lineQueues[node] = queue
	end

	table.insert(queue, record)
	record.stateData.lineNode = node
	record.stateData.dwellStarted = nil

	Local.AdvanceLine(node)

	if record.kind == "Crowd" then
		record.stateData.impatience = 0
		local epoch = (record.stateData.impatienceEpoch or 0) + 1
		record.stateData.impatienceEpoch = epoch
		task.delay(NPCConfig.IMPATIENCE_ROLL_INTERVAL, function()
			Local.TickImpatience(record, epoch)
		end)
	end
end

function Local.LeaveLineQueue(record: NPCRecord)
	local node = record.stateData.lineNode :: BasePart?
	if not node then return end

	local queue = Local.lineQueues[node]
	if queue then
		local index = table.find(queue, record)
		if index then
			table.remove(queue, index)
		end
	end

	record.stateData.lineNode = nil
	record.stateData.slotIndex = nil
	record.stateData.dwellStarted = nil

	Local.AdvanceLine(node)
end

function Local.StartLineDwell(node: BasePart, record: NPCRecord)
	record.stateData.dwellStarted = true

	task.delay(NPCConfig.LINE_DWELL, function()
		-- Re-verify the record is still exactly where we left it — it may have
		-- been pulled out of the queue by panic/cleanup/despawn in the meantime.
		if Local.records[record.model] ~= record then return end
		if record.state ~= "Queueing" then return end
		if record.stateData.lineNode ~= node or record.stateData.slotIndex ~= 1 then return end

		Local.LeaveLineQueue(record)
		Local.AdvanceOrWait(record, node)
	end)
end

-- [[ Private Functions — Seat node ]] --
function Local.IsSeatOccupied(node: BasePart): boolean
	return Local.seatOccupancy[node] ~= nil
end

function Local.FindSeatInstance(node: BasePart): (Seat | VehicleSeat)?
	if node:IsA("Seat") or node:IsA("VehicleSeat") then
		return node :: Seat
	end

	local graphNode = Local.graph[node]
	local link = graphNode and graphNode.link
	if link and (link:IsA("Seat") or link:IsA("VehicleSeat")) then
		return link :: Seat
	end

	return nil
end

function Local.OccupySeat(node: BasePart, record: NPCRecord)
	Local.seatOccupancy[node] = record
	Local.SetNodeOccupied(node, true)
	record.stateData.seatNode = node
	Local.SetState(record, "Seated")

	local seatInstance = Local.FindSeatInstance(node)
	if seatInstance then
		seatInstance:Sit(record.humanoid)
	else
		record.humanoid.Sit = true
	end

	local duration = math.random(NPCConfig.SEAT_MIN_DURATION, NPCConfig.SEAT_MAX_DURATION)

	task.delay(duration, function()
		if Local.records[record.model] ~= record then return end
		if record.state ~= "Seated" or record.stateData.seatNode ~= node then return end
		Local.StandUpFromSeat(node, record)
	end)
end

function Local.ReleaseSeat(record: NPCRecord)
	local node = record.stateData.seatNode :: BasePart?
	if not node then return end

	if Local.seatOccupancy[node] == record then
		Local.seatOccupancy[node] = nil
		Local.SetNodeOccupied(node, false)
	end
	record.stateData.seatNode = nil
end

function Local.StandUpFromSeat(node: BasePart, record: NPCRecord)
	Local.ReleaseSeat(record)

	local humanoid = record.humanoid
	if humanoid and humanoid.Parent then
		humanoid.Sit = false
		humanoid.Jump = true
	end

	Local.AdvanceOrWait(record, node)
end

-- [[ Private Functions — Interaction / Stand nodes (cosmetic dwell points) ]] --
function Local.ReleaseDwell(record: NPCRecord)
	local node = record.stateData.dwellNode :: BasePart?
	if not node then return end

	if Local.nodeOccupancy[node] == record then
		Local.nodeOccupancy[node] = nil
		Local.SetNodeOccupied(node, false)
	end
	record.stateData.dwellNode = nil
end

function Local.DwellAtNode(node: BasePart, record: NPCRecord, minDuration: number, maxDuration: number)
	Local.nodeOccupancy[node] = record
	Local.SetNodeOccupied(node, true)
	record.stateData.dwellNode = node

	local duration = math.random(minDuration, maxDuration)
	task.delay(duration, function()
		if Local.records[record.model] ~= record then return end
		if record.stateData.dwellNode ~= node then return end

		Local.ReleaseDwell(record)
		Local.AdvanceOrWait(record, node)
	end)
end

-- Vending Machine / Inquiry Desk / Shelf / ATM — purely cosmetic, no economy
-- or system hookup (see NPC-AI.md).
function Local.InteractAtNode(node: BasePart, record: NPCRecord)
	Local.DwellAtNode(node, record, NPCConfig.INTERACTION_DWELL_MIN, NPCConfig.INTERACTION_DWELL_MAX)
end

function Local.StandAtNode(node: BasePart, record: NPCRecord)
	Local.DwellAtNode(node, record, NPCConfig.STAND_DWELL_MIN, NPCConfig.STAND_DWELL_MAX)
end

-- [[ Private Functions — Conveyor node (bag-in-transit) ]] --

-- Skips the bag-drop step and just passes the NPC through — used when there's
-- nothing to drop or the node is missing the Link its exit point needs.
function Local.PassThroughConveyor(node: BasePart, record: NPCRecord)
	Local.AdvanceOrWait(record, node)
end

function Local.StartConveyorTransit(node: BasePart, record: NPCRecord)
	local npc = record.model
	local heldItemName = npc:GetAttribute("HeldItem")
	local graphNode = Local.graph[node]
	local exitNode = graphNode and graphNode.link

	if not heldItemName or heldItemName == "" or not exitNode then
		Local.PassThroughConveyor(node, record)
		return
	end

	local bag = ItemService.ForceDropItem(npc)
	if not bag or not bag.PrimaryPart then
		Local.PassThroughConveyor(node, record)
		return
	end

	local startPos = Local.GetNodePosition(node)
	local endPos = Local.GetNodePosition(exitNode)

	-- Automated checkpoint detection: the belt itself catches contraband, no
	-- TSA player required (real per NPC-AI.md — not just a cosmetic sound).
	if ItemService.GetContrabandItemCount(bag) > 0 then
		Shared.ForcePanic(startPos, NPCConfig.CONVEYOR_DETECT_RADIUS, NPCConfig.CONVEYOR_DETECT_REQUIRE_LOS)
	end

	bag:SetAttribute("OwnerNPCUID", record.uid)
	bag:SetAttribute("OnBelt", true)
	bag:PivotTo(CFrame.new(startPos))

	for _, part in bag:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end

	Local.beltBags[bag] = {
		npcUID = record.uid,
		startPos = startPos,
		endPos = endPos,
		startTime = workspace:GetServerTimeNow(),
		travelTime = NPCConfig.BELT_TRAVEL_TIME,
		arrived = false,
	}

	table.insert(record.connections, bag.Destroying:Once(function()
		Local.beltBags[bag] = nil
	end))

	Local.RunBeltTransit(bag)

	-- The NPC keeps walking through the checkpoint while its bag rides the
	-- belt separately; it reclaims (or fails to, if stolen) at the exit node.
	record.stateData.pendingBagNode = exitNode
	Local.SetState(record, "Commuting")
	Local.WalkTo(record, exitNode)
end

function Local.RunBeltTransit(bag: Model)
	task.spawn(function()
		while true do
			local info = Local.beltBags[bag]
			if not info then return end

			-- A player picking the bag up mid-belt (ItemService.PickupItem)
			-- reparents it off Workspace and strips the Interactable tag —
			-- that's the signal to stop driving it; the theft "just works"
			-- through the existing item code with no extra plumbing here.
			if not bag.Parent or not CollectionService:HasTag(bag, "Interactable") then
				Local.beltBags[bag] = nil
				return
			end

			local elapsed = workspace:GetServerTimeNow() - info.startTime
			local alpha = math.clamp(elapsed / info.travelTime, 0, 1)
			bag:PivotTo(CFrame.new(info.startPos:Lerp(info.endPos, alpha)))

			if alpha >= 1 then
				info.arrived = true
				Local.CompleteBeltArrival(bag, info)
				return
			end

			task.wait(0.1)
		end
	end)
end

-- If the owning NPC is already sitting at the exit node waiting (it can beat
-- the bag there — belt travel time and walk time aren't coupled), hand the
-- bag back immediately. Otherwise leave it sitting (still Interactable/
-- OnBelt) for a later TryReclaimBag call, or for a player to just grab it.
function Local.CompleteBeltArrival(bag: Model, info: BeltBagInfo)
	local npc = Shared.FindNPCById(info.npcUID)
	local record = npc and Local.records[npc]
	if not record then return end
	if record.stateData.pendingBagNode ~= record.currentNode then return end

	Local.beltBags[bag] = nil
	record.stateData.pendingBagNode = nil

	if bag.Parent and CollectionService:HasTag(bag, "Interactable") then
		bag:SetAttribute("OnBelt", nil)
		ItemService.EquipNPCItem(record.model, bag)
	end
end

-- Called on arrival at a Conveyor's paired exit node, before the arriving
-- node's own handler runs. If the bag hasn't finished its belt ride yet,
-- leaves pendingBagNode set so CompleteBeltArrival can hand it off the
-- moment it lands instead of snapping it out of mid-air. Silently no-ops if
-- the bag was stolen mid-belt.
function Local.TryReclaimBag(record: NPCRecord)
	local targetBag: Model? = nil
	local targetInfo: BeltBagInfo? = nil

	for bag, info in Local.beltBags do
		if info.npcUID == record.uid then
			targetBag, targetInfo = bag, info
			break
		end
	end

	if not targetBag or not targetInfo then
		record.stateData.pendingBagNode = nil
		return
	end

	if not targetInfo.arrived then
		return -- still riding the belt; CompleteBeltArrival will finish this
	end

	Local.beltBags[targetBag] = nil
	record.stateData.pendingBagNode = nil

	if targetBag.Parent and CollectionService:HasTag(targetBag, "Interactable") then
		targetBag:SetAttribute("OnBelt", nil)
		ItemService.EquipNPCItem(record.model, targetBag)
	end
end

-- [[ Private Functions — Decoys ]] --

-- Cooldown-gated random chance, rolled each time a Decoy would otherwise
-- resolve its next Commuting node: sends it toward the nearest DepositZone
-- instead of its normal boarding route, to visually mimic a Smuggler.
function Local.MaybeDivertDecoy(record: NPCRecord): BasePart?
	local now = workspace:GetServerTimeNow()
	if now < (record.stateData.divertCooldownUntil or 0) then return nil end

	record.stateData.divertCooldownUntil = now + NPCConfig.DECOY_DIVERT_COOLDOWN
	if math.random() >= NPCConfig.DECOY_DIVERT_CHANCE then return nil end

	return Local.FindNearestDepositZoneNode()
end

-- The nearest graph node to any DepositZone-tagged part in the active map —
-- Decoys path to it using ordinary node movement rather than a new pathing
-- mode. Purely cosmetic bait: DepositService is entirely Player-keyed, so a
-- Decoy standing in the zone can never actually trigger/complete a deposit.
function Local.FindNearestDepositZoneNode(): BasePart?
	local activeMap = MapService.GetActiveMap()
	if not activeMap then return nil end

	local bestNode, bestDist = nil, math.huge

	for _, zonePart in CollectionService:GetTagged("DepositZone") do
		if not zonePart:IsA("BasePart") or not zonePart:IsDescendantOf(activeMap) then continue end

		for node in Local.graph do
			local dist = (Local.GetNodePosition(node) - zonePart.Position).Magnitude
			if dist < bestDist then
				bestDist = dist
				bestNode = node
			end
		end
	end

	return bestNode
end

function Local.GetJailModel(): Model?
	local tagged = CollectionService:GetTagged("Jail")
	if #tagged == 0 then return nil end
	return tagged[1] :: Model
end

-- Mirrors JailService.Local.TeleportToJail's feet-adjust math so Decoys land
-- on the same physical Jail model players use, without depending on
-- JailService itself (it's entirely Player-keyed).
function Local.GetJailStandCFrame(jailModel: Model, record: NPCRecord): CFrame
	local pivotCFrame = jailModel:GetPivot()
	local modelSize = jailModel:GetExtentsSize()
	local floorY = pivotCFrame.Position.Y - (modelSize.Y / 2)
	local spawnY = floorY + record.humanoid.HipHeight + (record.hrp.Size.Y / 2)
	return CFrame.new(pivotCFrame.Position.X, spawnY, pivotCFrame.Position.Z)
end

-- Destroys the jailed Decoy and spawns a fresh one in its place, keeping the
-- decoy sub-cap constant (churn, not release-back-into-the-crowd).
function Local.ChurnDecoy(record: NPCRecord)
	if RoundService.GetState() ~= "InProgress" and RoundService.GetState() ~= "Starting" then
		return -- round is already tearing down; DespawnAll handles cleanup
	end

	Local.CleanupRecord(record.model)
	Local.SpawnNPC("Decoy")
end

-- [[ Public Functions ]] --

-- Called by StealService whenever an NPC is successfully stolen from or
-- catches a Smuggler mid-steal.
function Shared.ForceAlert(npc: Model)
	local record = Local.records[npc]
	if not record then return end
	Local.EnterAlert(record)
end

-- Public hook for the (future) Gate Lockdown service, and for the violence-
-- witness reaction wired to RagdollService.OnRagdolled in Shared.Init.
-- NPCAIService never depends on the caller existing.
function Shared.ForcePanic(position: Vector3, radius: number, requireLineOfSight: boolean?)
	for _, record in Local.records do
		if record.state == "DecoyJailed" then continue end

		local npcPos = record.hrp.Position
		if (npcPos - position).Magnitude > radius then continue end

		if requireLineOfSight and not Local.HasClearLine(position, npcPos, { _npcsFolder }) then
			continue
		end

		Local.EnterPanic(record)
	end
end

function Shared.GetNPCKind(npc: Model): NPCKind?
	local record = Local.records[npc]
	return record and record.kind
end

function Shared.IsNPC(npc: Model): boolean
	return Local.records[npc] ~= nil
end

-- Internal counterpart to Shared.FindNPCById that returns the record itself
-- rather than the Model — used by OnDecisionReported, which needs the record
-- directly rather than an extra Local.records[npc] indirection.
function Local.FindRecordById(uid: string?): NPCRecord?
	if not uid or uid == "" then return nil end

	for _, record in Local.records do
		if record.uid == uid then
			return record
		end
	end

	return nil
end

function Shared.FindNPCById(uid: string?): Model?
	local record = Local.FindRecordById(uid)
	return record and record.model
end

-- Called by ArrestService when a TSA player "arrests" a Decoy: no stat
-- change (no reward, no strike) — the Decoy is held at the Jail location and
-- then destroyed + replaced by a fresh one once its timer elapses.
function Shared.CaptureDecoy(npc: Model)
	local record = Local.records[npc]
	if not record or record.kind ~= "Decoy" or record.state == "DecoyJailed" then return end

	Local.InterruptForReaction(record)
	record.targetNode = nil
	record.moveTargetPos = nil
	record.waypoints = nil
	record.waypointIndex = nil
	Local.SetState(record, "DecoyJailed")
	record.humanoid.WalkSpeed = 0

	local jailModel = Local.GetJailModel()
	if jailModel then
		record.model:PivotTo(Local.GetJailStandCFrame(jailModel, record))
	else
		warn("[NPCAIService] No model tagged 'Jail' found — Decoy held in place instead")
	end

	task.delay(NPCConfig.DECOY_JAIL_DURATION, function()
		if Local.records[record.model] ~= record then return end
		if record.state ~= "DecoyJailed" then return end
		Local.ChurnDecoy(record)
	end)
end

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	Local.DespawnAll()
end

return Shared
