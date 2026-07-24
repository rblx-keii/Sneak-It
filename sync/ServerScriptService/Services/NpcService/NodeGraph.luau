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

-- [[ Auto-search ]] --

function NodeGraph.FindNearestNode(
	nodesFolder: Instance,
	fromPos: Vector3,
	zones: { string },
	exclude: { BasePart? },
	ignore: { Instance? },
	avoidLinkBackTo: BasePart?,
	skipNodeTypes: { [string]: boolean }?,
	towardGoal: Vector3?,
	awayFromPos: Vector3?
): BasePart?
	local excludeSet: { [BasePart]: boolean } = {}
	for _, part in exclude do
		if part then excludeSet[part] = true end
	end

	local rankPos = towardGoal or fromPos
	local best: BasePart? = nil
	local bestDist = if towardGoal then (fromPos - towardGoal).Magnitude else math.huge
	local minDistFromAway = awayFromPos and (fromPos - awayFromPos).Magnitude or nil

	for _, zone in zones do
		for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zone) do
			if excludeSet[node] then continue end
			if NodeGraph.IsEntryNode(node) then continue end
			if avoidLinkBackTo and NodeGraph.GetLink(node) == avoidLinkBackTo then continue end
			if skipNodeTypes and skipNodeTypes[NodeGraph.GetNodeType(node)] then continue end
			if NodeGraph.GetNodeType(node) == "linenode" and NodeGraph.GetLineGroup(node):GetAttribute("LineIsFull") then continue end

			local pos = NodeGraph.GetNodePosition(node)
			if minDistFromAway and (pos - (awayFromPos :: Vector3)).Magnitude <= minDistFromAway then continue end

			local distance = (pos - rankPos).Magnitude

			local reachable = if towardGoal then true else NodeGraph.HasClearLine(fromPos, pos, ignore)
			if distance < bestDist and reachable then
				bestDist = distance
				best = node
			end
		end
	end

	return best
end

function NodeGraph.FindRandomSeatNode(nodesFolder: Instance, zoneName: string, fromPos: Vector3, exclude: { BasePart? }): BasePart?
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

	-- Verify PathfindingService can actually route there before committing —
	-- without this a seat tucked behind furniture/obstructions could get
	-- picked, movement would fail to reach it, and the stuck-timeout would
	-- eventually force-arrive the NPC from wherever it got stuck, snapping
	-- it onto the seat (Seat:Sit always welds to the seat's CFrame) from far
	-- away. If unreachable, just skip sitting this decision — next tick will
	-- roll again.
	if not NodeGraph.IsPathReachable(fromPos, NodeGraph.GetNodePosition(picked)) then
		return nil
	end

	return picked
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
