--|| Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)

local NodeGraph = {}

--|| Constants
local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAYCAST_PARAMS.CollisionGroup = "NPC"

local PATH_AGENT_PARAMS = {
	AgentRadius = NPCConfig.PATH_AGENT_RADIUS,
	AgentHeight = NPCConfig.PATH_AGENT_HEIGHT,
	AgentCanJump = NPCConfig.PATH_AGENT_CAN_JUMP,
	AgentCanClimb = NPCConfig.PATH_AGENT_CAN_CLIMB,
	WaypointSpacing = NPCConfig.PATH_WAYPOINT_SPACING,
}

--|| Private Functions
local function normalize(name: string): string
	return name:gsub(" ", ""):lower()
end

-- [[ Zone / node identity ]] --
-- Depart is now an ordinary zone subfolder (named exactly "Depart") like
-- every other zone, holding however many gate/waiting-area nodes — no
-- special-cased "direct child of nodesFolder" handling anymore.
function NodeGraph.GetZone(node: BasePart, nodesFolder: Instance): string
	local parent = node.Parent
	if parent and parent:IsA("BasePart") and normalize(parent.Name) == "linenode" then
		parent = parent.Parent
	end

	return (parent and parent.Name) or "Unknown"
end

function NodeGraph.GetZoneFolder(nodesFolder: Instance, zoneName: string): Instance?
	return nodesFolder:FindFirstChild(zoneName)
end

function NodeGraph.GetNodeType(node: BasePart): string
	local parent = node.Parent
	if parent and parent:IsA("BasePart") and normalize(parent.Name) == "linenode" and normalize(node.Name) == "slotnode" then
		return "linenode"
	end
	return normalize(node.Name)
end

function NodeGraph.IsEntryNode(node: BasePart): boolean
	return normalize(node.Name) == "entrynode"
end

-- A Transition Node lives under a zone's own Folder and is the mandatory
-- checkpoint an NPC must reach before that zone's Auto-search is allowed to
-- consider anything in the next zone — it carries a Link (like any other
-- linked node) pointing into whichever node/zone comes next.
function NodeGraph.IsTransitionNode(node: BasePart): boolean
	return normalize(node.Name) == "transitionnode"
end

function NodeGraph.GetTransitionNodes(nodesFolder: Instance, zoneName: string): { BasePart }
	local result = {}
	for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zoneName) do
		if NodeGraph.IsTransitionNode(node) then
			table.insert(result, node)
		end
	end
	return result
end

function NodeGraph.GetLink(node: BasePart): BasePart?
	local linkValue = node:FindFirstChild("Link")
	if linkValue and linkValue:IsA("ObjectValue") and linkValue.Value and linkValue.Value:IsA("BasePart") then
		return linkValue.Value :: BasePart
	end
	return nil
end

function NodeGraph.GetEntryNode(node: BasePart): BasePart?
	local entryValue = node:FindFirstChild("Entry")
	if entryValue and entryValue:IsA("ObjectValue") and entryValue.Value and entryValue.Value:IsA("BasePart") then
		return entryValue.Value :: BasePart
	end
	return nil
end

function NodeGraph.GetSeatObject(node: BasePart): Seat?
	local seatValue = node:FindFirstChild("SeatObject")
	if seatValue and seatValue:IsA("ObjectValue") and seatValue.Value and seatValue.Value:IsA("Seat") then
		return seatValue.Value :: Seat
	end
	return nil
end

function NodeGraph.GetNodePosition(node: BasePart): Vector3
	local attachment = node:FindFirstChildOfClass("Attachment")
	if attachment then
		return attachment.WorldPosition
	end
	return node.Position
end

function NodeGraph.EnumerateZoneNodes(nodesFolder: Instance, zoneName: string): { BasePart }
	local result = {}
	local folder = NodeGraph.GetZoneFolder(nodesFolder, zoneName)
	if not folder then return result end

	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(result, child)

			if normalize(child.Name) == "linenode" then
				for _, slot in child:GetChildren() do
					if slot:IsA("BasePart") and normalize(slot.Name) == "slotnode" then
						table.insert(result, slot)
					end
				end
			end
		end
	end

	return result
end

function NodeGraph.EnumerateAllNodes(nodesFolder: Instance): { BasePart }
	local result = {}
	for _, child in nodesFolder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(result, child)
		elseif child:IsA("Folder") then
			for _, part in NodeGraph.EnumerateZoneNodes(nodesFolder, child.Name) do
				table.insert(result, part)
			end
		end
	end
	return result
end

-- [[ Movement helpers ]] --

function NodeGraph.GetMovementTargetPosition(node: BasePart, spreadRadius: number, nodesFolder: Instance?): Vector3
	local basePos = NodeGraph.GetNodePosition(node)
	if NodeGraph.GetNodeType(node) ~= "node" then
		return basePos
	end

	-- Depart Folder nodes sit in a narrow gate corridor — the normal spread
	-- radius can land the target position inside a doorframe/wall and get
	-- the NPC stuck. Clamp it down there.
	local radius = spreadRadius
	if nodesFolder and NodeGraph.GetZone(node, nodesFolder) == "Depart" then
		radius = math.min(radius, NPCConfig.DEPART_NODE_SPREAD_RADIUS)
	end

	local angle = math.random() * math.pi * 2
	local dist = math.random() * radius
	return basePos + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
end

function NodeGraph.HasClearLine(fromPos: Vector3, toPos: Vector3, ignore: { Instance? }): boolean
	local direction = toPos - fromPos
	if direction.Magnitude < 0.05 then return true end

	RAYCAST_PARAMS.FilterDescendantsInstances = ignore :: { Instance }
	local result = Workspace:Raycast(fromPos, direction, RAYCAST_PARAMS)
	return result == nil
end

-- Node-pair line-of-sight cache: Auto-search re-checks the same pairs of
-- nodes over and over (every decision, for every NPC), so this avoids
-- redundant raycasts for the common case where nothing nearby changed.
-- Persistent rather than time-limited — see PrefillLoSCache, which computes
-- the whole graph once during map load while no NPCs or players are around
-- to falsely block a ray, so what lands in the cache is the true static-
-- geometry answer. It's only ever invalidated by known geometry changes
-- (see GateService's door open/close, the only thing in this map with the
-- same effect on raycasts as on physics — see the CollisionGroup rationale
-- below), never by time.
local _losCache: { [BasePart]: { [BasePart]: boolean } } = {}

function NodeGraph.InvalidateLoSCache()
	table.clear(_losCache)
end

function NodeGraph.HasClearLineBetweenNodes(nodeA: BasePart, nodeB: BasePart, ignore: { Instance? }): boolean
	if nodeA == nodeB then return true end

	local cached = _losCache[nodeA] and _losCache[nodeA][nodeB]
	if cached ~= nil then
		return cached
	end

	local result = NodeGraph.HasClearLine(NodeGraph.GetNodePosition(nodeA), NodeGraph.GetNodePosition(nodeB), ignore)

	_losCache[nodeA] = _losCache[nodeA] or {}
	_losCache[nodeA][nodeB] = result
	_losCache[nodeB] = _losCache[nodeB] or {}
	_losCache[nodeB][nodeA] = result -- LoS is symmetric — one raycast covers both directions

	return result
end

-- Computes and caches every node-pair's line of sight up front, meant to run
-- during the round's map-loading phase — before any NPC has spawned and
-- before players are roaming the map — so the cache's initial (and, absent
-- an invalidation, only) computation reflects nothing but the static map
-- geometry, not a transient obstruction. O(n^2) in node count, but it's a
-- one-time load-time cost rather than a per-frame one.
function NodeGraph.PrefillLoSCache(nodesFolder: Instance)
	local nodes = NodeGraph.EnumerateAllNodes(nodesFolder)

	for i = 1, #nodes do
		for j = i + 1, #nodes do
			NodeGraph.HasClearLineBetweenNodes(nodes[i], nodes[j], {})
		end
	end
end

-- A straight-line raycast can pass or fail for reasons that have nothing to
-- do with whether the navmesh can actually route an agent there (furniture
-- gaps, agent radius clearance, etc.) — this asks PathfindingService itself,
-- the same way the actual walk to the node will be computed.
function NodeGraph.IsPathReachable(fromPos: Vector3, toPos: Vector3): boolean
	local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)
	local computeOk = pcall(function()
		path:ComputeAsync(fromPos, toPos)
	end)
	return computeOk and path.Status == Enum.PathStatus.Success
end

-- PathfindingService can report Success while quietly snapping the goal to
-- the nearest walkable point, which can be several studs from a target
-- that's embedded in/behind solid geometry (e.g. a Seat Node marker placed
-- inside the chair mesh rather than on the floor beside it) — walking there
-- looks normal, but the final short-range snap (Seat:Sit always welds
-- exactly onto the seat) becomes a visible jump instead of an imperceptible
-- one. This additionally checks the path's last waypoint actually lands
-- within tolerance of the true target before trusting it.
function NodeGraph.IsPreciselyReachable(fromPos: Vector3, toPos: Vector3, tolerance: number): boolean
	local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)
	local computeOk = pcall(function()
		path:ComputeAsync(fromPos, toPos)
	end)
	if not computeOk or path.Status ~= Enum.PathStatus.Success then
		return false
	end

	local waypoints = path:GetWaypoints()
	local lastWaypoint = waypoints[#waypoints]
	if not lastWaypoint then
		return false
	end

	return (lastWaypoint.Position - toPos).Magnitude <= tolerance
end

-- [[ Auto-search ]] --

function NodeGraph.FindNearestNode(
	nodesFolder: Instance,
	fromNode: BasePart,
	zones: { string },
	exclude: { BasePart? },
	ignore: { Instance? },
	avoidLinkBackTo: BasePart?,
	skipNodeTypes: { [string]: boolean }?,
	towardGoal: Vector3?,
	awayFromPos: Vector3?
): BasePart?
	local fromPos = NodeGraph.GetNodePosition(fromNode)

	local excludeSet: { [BasePart]: boolean } = {}
	for _, part in exclude do
		if part then excludeSet[part] = true end
	end

	local rankPos = towardGoal or fromPos
	local best: BasePart? = nil
	local bestDist = if towardGoal then (fromPos - towardGoal).Magnitude else math.huge
	local minDistFromAway = awayFromPos and (fromPos - awayFromPos).Magnitude or nil

	local function isCandidate(node: BasePart): boolean
		if excludeSet[node] then return false end
		if NodeGraph.IsEntryNode(node) then return false end
		if avoidLinkBackTo and NodeGraph.GetLink(node) == avoidLinkBackTo then return false end
		if skipNodeTypes and skipNodeTypes[NodeGraph.GetNodeType(node)] then return false end
		if NodeGraph.GetNodeType(node) == "linenode" and NodeGraph.GetLineGroup(node):GetAttribute("LineIsFull") then return false end
		if minDistFromAway and (NodeGraph.GetNodePosition(node) - (awayFromPos :: Vector3)).Magnitude <= minDistFromAway then return false end
		return true
	end

	local nearestOverall: BasePart? = nil
	local nearestOverallDist = math.huge

	for _, zone in zones do
		for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zone) do
			if not isCandidate(node) then continue end

			local pos = NodeGraph.GetNodePosition(node)
			local distance = (pos - rankPos).Magnitude

			if distance < nearestOverallDist then
				nearestOverallDist = distance
				nearestOverall = node
			end

			local reachable = if towardGoal then true else NodeGraph.HasClearLineBetweenNodes(fromNode, node, ignore)
			if distance < bestDist and reachable then
				bestDist = distance
				best = node
			end
		end
	end

	if best or towardGoal or not nearestOverall then
		return best
	end

	-- Nothing directly visible, but a genuinely nearer candidate exists —
	-- look for a single intermediate "bridge" node (from the same candidate
	-- pool) that's visible from both here and the true nearest node, and
	-- route through it instead of giving up entirely. Once actually standing
	-- on the bridge node, the next decision will re-run this search and (by
	-- construction) have direct line of sight to the real target.
	for _, zone in zones do
		for _, bridge in NodeGraph.EnumerateZoneNodes(nodesFolder, zone) do
			if bridge == nearestOverall then continue end
			if not isCandidate(bridge) then continue end

			if NodeGraph.HasClearLineBetweenNodes(fromNode, bridge, ignore)
				and NodeGraph.HasClearLineBetweenNodes(bridge, nearestOverall :: BasePart, ignore) then
				return bridge
			end
		end
	end

	return nil
end

-- Plain nearest-neighbor among a zone's Transition Nodes (plural — a zone
-- may have more than one, e.g. two gate entrances side by side). Used once
-- nothing else in the zone is any closer, to pick whichever Transition Node
-- is actually nearest right now.
function NodeGraph.FindNearestTransitionNode(nodesFolder: Instance, zoneName: string, fromNode: BasePart, exclude: { BasePart? }, ignore: { Instance? }): BasePart?
	local excludeSet: { [BasePart]: boolean } = {}
	for _, part in exclude do
		if part then excludeSet[part] = true end
	end

	local fromPos = NodeGraph.GetNodePosition(fromNode)
	local best: BasePart? = nil
	local bestDist = math.huge

	for _, node in NodeGraph.GetTransitionNodes(nodesFolder, zoneName) do
		if excludeSet[node] then continue end
		if not NodeGraph.GetLink(node) then continue end -- unlinked — a dead end, not a usable crossing point

		local dist = (NodeGraph.GetNodePosition(node) - fromPos).Magnitude
		if dist < bestDist and NodeGraph.HasClearLineBetweenNodes(fromNode, node, ignore) then
			bestDist = dist
			best = node
		end
	end

	return best
end

function NodeGraph.FindRandomSeatNode(nodesFolder: Instance, zoneName: string, fromNode: BasePart, exclude: { BasePart? }, ignore: { Instance? }): BasePart?
	local excludeSet: { [BasePart]: boolean } = {}
	for _, part in exclude do
		if part then excludeSet[part] = true end
	end

	local candidates: { BasePart } = {}
	for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zoneName) do
		if excludeSet[node] then continue end
		if NodeGraph.GetNodeType(node) ~= "seatnode" then continue end
		if NodeGraph.IsOccupied(node) or NodeGraph.IsSeatReserved(node) then continue end
		table.insert(candidates, node)
	end

	if #candidates == 0 then return nil end

	local picked = candidates[math.random(1, #candidates)]
	local fromPos = NodeGraph.GetNodePosition(fromNode)
	local seatPos = NodeGraph.GetNodePosition(picked)

	-- Already visible from here, and PathfindingService can route precisely
	-- there (a plain Success check isn't enough on its own — see
	-- IsPreciselyReachable) — go straight to it. The final short Seat:Sit()
	-- snap from this close is imperceptible.
	if NodeGraph.HasClearLineBetweenNodes(fromNode, picked, ignore)
		and NodeGraph.IsPreciselyReachable(fromPos, seatPos, NPCConfig.ARRIVAL_TOLERANCE) then
		return picked
	end

	-- Not visible yet — walk there via a node that can see both here and the
	-- seat (same bridging trick FindNearestNode uses for Auto-search)
	-- instead of committing to one long-range leg straight to a seat we
	-- can't even see from here. Once actually standing at the bridge, the
	-- next decision re-rolls and — now much closer — likely finds this or
	-- another seat within direct reach.
	for _, bridge in NodeGraph.EnumerateZoneNodes(nodesFolder, zoneName) do
		if bridge == picked or bridge == fromNode then continue end
		if excludeSet[bridge] then continue end

		if NodeGraph.HasClearLineBetweenNodes(fromNode, bridge, ignore)
			and NodeGraph.HasClearLineBetweenNodes(bridge, picked, ignore) then
			return bridge
		end
	end

	return nil
end

function NodeGraph.GetDepartPosition(nodesFolder: Instance): Vector3?
	local departNodes = NodeGraph.EnumerateZoneNodes(nodesFolder, "Depart")
	if #departNodes == 0 then return nil end
	return NodeGraph.GetNodePosition(departNodes[1])
end

-- [[ Line Node slot occupancy ]] --

function NodeGraph.IsPlayerNearby(position: Vector3, radius: number): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp and (hrp.Position - position).Magnitude <= radius then
			return true
		end
	end
	return false
end

function NodeGraph.IsOccupied(node: BasePart): boolean
	return node:GetAttribute("Occupied") == true
end

function NodeGraph.IsSlotNode(node: BasePart): boolean
	local parent = node.Parent
	return parent ~= nil and parent:IsA("BasePart") and normalize(parent.Name) == "linenode" and normalize(node.Name) == "slotnode"
end

function NodeGraph.GetLineGroup(node: BasePart): BasePart
	if NodeGraph.IsSlotNode(node) then
		return node.Parent :: BasePart
	end
	return node
end

function NodeGraph.UpdateLineFullAttribute(lineNode: BasePart)
	local full = NodeGraph.IsOccupied(lineNode)
	if full then
		for _, child in lineNode:GetChildren() do
			if child:IsA("BasePart") and normalize(child.Name) == "slotnode" and not NodeGraph.IsOccupied(child) then
				full = false
				break
			end
		end
	end
	lineNode:SetAttribute("LineIsFull", full)
end

function NodeGraph.TryClaimSlot(node: BasePart, playerRadius: number): boolean
	if NodeGraph.IsOccupied(node) then return false end
	if NodeGraph.IsPlayerNearby(NodeGraph.GetNodePosition(node), playerRadius) then return false end

	node:SetAttribute("Occupied", true)
	NodeGraph.UpdateLineFullAttribute(NodeGraph.GetLineGroup(node))
	return true
end

function NodeGraph.ReleaseSlot(node: BasePart)
	node:SetAttribute("Occupied", false)
	NodeGraph.UpdateLineFullAttribute(NodeGraph.GetLineGroup(node))
end

function NodeGraph.FindNextSlotForward(lineNode: BasePart, currentSlot: BasePart): BasePart?
	local linePos = NodeGraph.GetNodePosition(lineNode)
	local currentDist = (NodeGraph.GetNodePosition(currentSlot) - linePos).Magnitude

	local best, bestDist = nil, currentDist

	local function consider(slot: BasePart)
		if slot == currentSlot or NodeGraph.IsOccupied(slot) then return end
		local dist = (NodeGraph.GetNodePosition(slot) - linePos).Magnitude
		if dist < bestDist then
			bestDist = dist
			best = slot
		end
	end

	consider(lineNode)
	for _, child in lineNode:GetChildren() do
		if child:IsA("BasePart") and normalize(child.Name) == "slotnode" then
			consider(child)
		end
	end

	return best
end

function NodeGraph.EnumerateLineGroups(nodesFolder: Instance, zones: { string }): { BasePart }
	local result = {}
	for _, zone in zones do
		for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zone) do
			if NodeGraph.GetNodeType(node) == "linenode" and not NodeGraph.IsSlotNode(node) then
				table.insert(result, node)
			end
		end
	end
	return result
end

function NodeGraph.GetLineEnRouteCount(lineNode: BasePart): number
	return lineNode:GetAttribute("EnRouteCount") :: number or 0
end

function NodeGraph.AddLineEnRoute(lineNode: BasePart, delta: number)
	lineNode:SetAttribute("EnRouteCount", math.max(NodeGraph.GetLineEnRouteCount(lineNode) + delta, 0))
end

function NodeGraph.GetLineLoad(lineNode: BasePart): number
	local occupied = NodeGraph.IsOccupied(lineNode) and 1 or 0
	for _, child in lineNode:GetChildren() do
		if child:IsA("BasePart") and normalize(child.Name) == "slotnode" and NodeGraph.IsOccupied(child) then
			occupied += 1
		end
	end
	return occupied + NodeGraph.GetLineEnRouteCount(lineNode)
end

function NodeGraph.GetEnRouteLine(npc: Model): BasePart?
	local value = npc:FindFirstChild("EnRouteLine")
	if value and value:IsA("ObjectValue") and value.Value and value.Value:IsA("BasePart") then
		return value.Value :: BasePart
	end
	return nil
end

function NodeGraph.SetEnRouteLine(npc: Model, lineNode: BasePart?)
	local previous = NodeGraph.GetEnRouteLine(npc)
	if previous == lineNode then return end

	if previous then
		NodeGraph.AddLineEnRoute(previous, -1)
	end
	if lineNode then
		NodeGraph.AddLineEnRoute(lineNode, 1)
	end

	local value = npc:FindFirstChild("EnRouteLine") :: ObjectValue?
	if not value then
		value = Instance.new("ObjectValue")
		value.Name = "EnRouteLine"
		value.Parent = npc
	end
	value.Value = lineNode
end

-- [[ Seat Node occupancy ]] --

function NodeGraph.SyncSeatOccupiedAttribute(seatNode: BasePart)
	local seat = NodeGraph.GetSeatObject(seatNode)
	seatNode:SetAttribute("Occupied", seat ~= nil and seat.Occupant ~= nil)
end

function NodeGraph.IsSeatReserved(seatNode: BasePart): boolean
	return seatNode:GetAttribute("Reserved") == true
end

function NodeGraph.TryReserveSeat(seatNode: BasePart): boolean
	if NodeGraph.IsOccupied(seatNode) or NodeGraph.IsSeatReserved(seatNode) then return false end
	seatNode:SetAttribute("Reserved", true)
	return true
end

function NodeGraph.ReleaseSeatReservation(seatNode: BasePart)
	seatNode:SetAttribute("Reserved", false)
end

function NodeGraph.ResolveEntryRedirect(candidate: BasePart, currentNode: BasePart?): BasePart
	if NodeGraph.GetNodeType(candidate) ~= "linenode" then return candidate end

	local mainSlot = candidate
	if normalize(candidate.Name) == "slotnode" then
		mainSlot = candidate.Parent :: BasePart
	end

	local entry = NodeGraph.GetEntryNode(mainSlot)
	if not entry then return candidate end

	if currentNode == entry then return candidate end
	if currentNode == mainSlot then return candidate end
	if currentNode and currentNode.Parent == mainSlot then return candidate end

	return entry
end

return NodeGraph
