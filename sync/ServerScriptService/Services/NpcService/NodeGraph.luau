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

function NodeGraph.IsConveyorNode(node: BasePart): boolean
	return normalize(node.Name) == "conveyornode"
end

function NodeGraph.IsPickupNode(node: BasePart): boolean
	return normalize(node.Name) == "pickupnode"
end

function NodeGraph.GetLink(node: BasePart): BasePart?
	local linkValue = node:FindFirstChild("Link")
	if linkValue and linkValue:IsA("ObjectValue") and linkValue.Value and linkValue.Value:IsA("BasePart") then
		return linkValue.Value :: BasePart
	end
	return nil
end

function NodeGraph.GetPickupNode(node: BasePart): BasePart?
	local pickupValue = node:FindFirstChild("Pickup")
	if pickupValue and pickupValue:IsA("ObjectValue") and pickupValue.Value and pickupValue.Value:IsA("BasePart") then
		return pickupValue.Value :: BasePart
	end
	return nil
end

function NodeGraph.GetSubNode(node: BasePart, subName: string): BasePart?
	local subFolder = node:FindFirstChild("SubNodes")
	if not subFolder then return nil end

	local sub = subFolder:FindFirstChild(subName)
	return sub and sub:IsA("BasePart") and sub or nil
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

function NodeGraph.SetSeatObject(node: BasePart, seat: Seat)
	local seatValue = node:FindFirstChild("SeatObject") :: ObjectValue?
	if not seatValue then
		seatValue = Instance.new("ObjectValue")
		seatValue.Name = "SeatObject"
		seatValue.Parent = node
	end
	(seatValue :: ObjectValue).Value = seat
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
	if not nodesFolder or not nodesFolder.Parent then return {} end

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
	_losCache[nodeB][nodeA] = result

	return result
end

function NodeGraph.PrefillLoSCache(nodesFolder: Instance)
	local nodes = NodeGraph.EnumerateAllNodes(nodesFolder)

	for i = 1, #nodes do
		for j = i + 1, #nodes do
			NodeGraph.HasClearLineBetweenNodes(nodes[i], nodes[j], {})
		end
	end
end

function NodeGraph.IsPathReachable(fromPos: Vector3, toPos: Vector3): boolean
	local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)
	local computeOk = pcall(function()
		path:ComputeAsync(fromPos, toPos)
	end)
	return computeOk and path.Status == Enum.PathStatus.Success
end

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

function NodeGraph.GetNodesInZone(
	nodesFolder: Instance,
	zones: { string },
	currentPos: Vector3,
	exclusive: boolean,
	filter: { string }
): { BasePart }
	local filterSet: { [string]: boolean } = {}
	for _, nodeType in filter do
		filterSet[nodeType] = true
	end

	local result: { BasePart } = {}
	for _, zone in zones do
		for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zone) do
			if NodeGraph.IsEntryNode(node) then continue end

			local matches = filterSet[NodeGraph.GetNodeType(node)] == true
			if exclusive == matches then continue end

			table.insert(result, node)
		end
	end

	table.sort(result, function(a, b)
		return (NodeGraph.GetNodePosition(a) - currentPos).Magnitude < (NodeGraph.GetNodePosition(b) - currentPos).Magnitude
	end)

	return result
end

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

	local best: BasePart? = nil
	local bestDist = math.huge
	local currentDistToGoal = towardGoal and (fromPos - towardGoal).Magnitude or nil
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

			if towardGoal then
				local distToGoal = (pos - (towardGoal :: Vector3)).Magnitude
				if distToGoal >= (currentDistToGoal :: number) then continue end

				local distFromMe = (pos - fromPos).Magnitude
				if distFromMe < bestDist then
					bestDist = distFromMe
					best = node
				end
				continue
			end

			local distance = (pos - fromPos).Magnitude

			if distance < nearestOverallDist then
				nearestOverallDist = distance
				nearestOverall = node
			end

			local reachable = NodeGraph.HasClearLineBetweenNodes(fromNode, node, ignore)
			if distance < bestDist and reachable then
				bestDist = distance
				best = node
			end
		end
	end

	if best or towardGoal or not nearestOverall then
		return best
	end

	local bridgeCandidates: { BasePart } = {}
	for _, zone in zones do
		for _, bridge in NodeGraph.EnumerateZoneNodes(nodesFolder, zone) do
			if bridge == nearestOverall then continue end
			if not isCandidate(bridge) then continue end
			table.insert(bridgeCandidates, bridge)
		end
	end

	return NodeGraph.FindLoSBridge(nodesFolder, fromNode, nearestOverall :: BasePart, ignore, bridgeCandidates)
end

function NodeGraph.FindNearestTransitionNode(nodesFolder: Instance, zoneName: string, fromNode: BasePart, exclude: { BasePart? }, ignore: { Instance? }, candidates: { BasePart }?): BasePart?
	local excludeSet: { [BasePart]: boolean } = {}
	for _, part in exclude do
		if part then excludeSet[part] = true end
	end

	local fromPos = NodeGraph.GetNodePosition(fromNode)
	local best: BasePart? = nil
	local bestDist = math.huge

	local pool = candidates or NodeGraph.GetTransitionNodes(nodesFolder, zoneName)

	for _, node in pool do
		if excludeSet[node] then continue end
		if not candidates and not NodeGraph.GetLink(node) then continue end

		local dist = (NodeGraph.GetNodePosition(node) - fromPos).Magnitude
		if dist < bestDist and NodeGraph.HasClearLineBetweenNodes(fromNode, node, ignore) then
			bestDist = dist
			best = node
		end
	end

	return best
end

function NodeGraph.FindLoSBridge(nodesFolder: Instance, fromNode: BasePart, toNode: BasePart, ignore: { Instance? }, candidates: { BasePart }?): BasePart?
	local toPos = NodeGraph.GetNodePosition(toNode)
	local pool = candidates or NodeGraph.EnumerateAllNodes(nodesFolder)

	local best: BasePart? = nil
	local bestDist = math.huge

	for _, node in pool do
		if node == fromNode or node == toNode then continue end

		local dist = (NodeGraph.GetNodePosition(node) - toPos).Magnitude
		if dist >= bestDist then continue end

		if NodeGraph.HasClearLineBetweenNodes(fromNode, node, ignore)
			and NodeGraph.HasClearLineBetweenNodes(node, toNode, ignore) then
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

	if NodeGraph.HasClearLineBetweenNodes(fromNode, picked, ignore)
		and NodeGraph.IsPreciselyReachable(fromPos, seatPos, NPCConfig.ARRIVAL_TOLERANCE) then
		return picked
	end

	local bridgeCandidates: { BasePart } = {}
	for _, bridge in NodeGraph.EnumerateZoneNodes(nodesFolder, zoneName) do
		if bridge == picked or bridge == fromNode then continue end
		if excludeSet[bridge] then continue end
		table.insert(bridgeCandidates, bridge)
	end

	return NodeGraph.FindLoSBridge(nodesFolder, fromNode, picked, ignore, bridgeCandidates)
end

function NodeGraph.FindNearestPickupNode(nodesFolder: Instance, zoneName: string, fromNode: BasePart, ignore: { Instance? }): BasePart?
	local fromPos = NodeGraph.GetNodePosition(fromNode)
	local candidates: { BasePart } = {}

	for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zoneName) do
		if NodeGraph.IsPickupNode(node) then
			table.insert(candidates, node)
		end
	end

	if #candidates == 0 then return nil end

	table.sort(candidates, function(a, b)
		return (NodeGraph.GetNodePosition(a) - fromPos).Magnitude < (NodeGraph.GetNodePosition(b) - fromPos).Magnitude
	end)

	for _, picked in candidates do
		local pickedPos = NodeGraph.GetNodePosition(picked)
		if NodeGraph.HasClearLineBetweenNodes(fromNode, picked, ignore)
			and NodeGraph.IsPreciselyReachable(fromPos, pickedPos, NPCConfig.ARRIVAL_TOLERANCE) then
			return picked
		end
	end

	local nearest = candidates[1]
	local bridgeCandidates: { BasePart } = {}
	for _, bridge in NodeGraph.EnumerateZoneNodes(nodesFolder, zoneName) do
		if bridge == nearest or bridge == fromNode then continue end
		table.insert(bridgeCandidates, bridge)
	end

	return NodeGraph.FindLoSBridge(nodesFolder, fromNode, nearest, ignore, bridgeCandidates)
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

function NodeGraph.FindNearestAvailableSlot(lineNode: BasePart): BasePart?
	local linePos = NodeGraph.GetNodePosition(lineNode)
	local best, bestDist = nil, math.huge

	local function consider(slot: BasePart)
		if NodeGraph.IsOccupied(slot) then return end
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

-- [[ Transition Node load balancing ]] --

function NodeGraph.GetTransitionEnRouteCount(transitionNode: BasePart): number
	return transitionNode:GetAttribute("EnRouteCount") :: number or 0
end

function NodeGraph.AddTransitionEnRoute(transitionNode: BasePart, delta: number)
	transitionNode:SetAttribute("EnRouteCount", math.max(NodeGraph.GetTransitionEnRouteCount(transitionNode) + delta, 0))
end

function NodeGraph.GetEnRouteTransition(npc: Model): BasePart?
	local value = npc:FindFirstChild("EnRouteTransition")
	if value and value:IsA("ObjectValue") and value.Value and value.Value:IsA("BasePart") then
		return value.Value :: BasePart
	end
	return nil
end

function NodeGraph.SetEnRouteTransition(npc: Model, transitionNode: BasePart?)
	local previous = NodeGraph.GetEnRouteTransition(npc)
	if previous == transitionNode then return end

	if previous then
		NodeGraph.AddTransitionEnRoute(previous, -1)
	end
	if transitionNode then
		NodeGraph.AddTransitionEnRoute(transitionNode, 1)
	end

	local value = npc:FindFirstChild("EnRouteTransition") :: ObjectValue?
	if not value then
		value = Instance.new("ObjectValue")
		value.Name = "EnRouteTransition"
		value.Parent = npc
	end
	value.Value = transitionNode
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

function NodeGraph.GetLineNodeForEntry(nodesFolder: Instance, zoneName: string, entryNode: BasePart): BasePart?
	for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zoneName) do
		if NodeGraph.GetNodeType(node) == "linenode" and NodeGraph.GetEntryNode(node) == entryNode then
			return node
		end
	end
	return nil
end

function NodeGraph.GetConveyorNodeForTransition(nodesFolder: Instance, zoneName: string, transitionNode: BasePart): BasePart?
	for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zoneName) do
		if NodeGraph.IsConveyorNode(node) and NodeGraph.GetLink(node) == transitionNode then
			return node
		end
	end
	return nil
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
