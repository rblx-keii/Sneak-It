-- Pure graph-reading/writing helpers over the Nodes folder's Instance tree —
-- deliberately stateless (no module-level Lua tables) since this module gets
-- required fresh inside every NPC's isolated Actor VM as well as the main
-- thread. Everything here reads/writes only Instances (Attributes,
-- ObjectValues, positions), never a central cache, so it behaves identically
-- regardless of which thread calls it.

--|| Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local NodeGraph = {}

--|| Constants
local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude

--|| Private Functions
local function normalize(name: string): string
	return name:gsub(" ", ""):lower()
end

-- [[ Zone / node identity ]] --

-- Zone subfolders live directly under `nodesFolder` (e.g. "Lobby",
-- "Concourse", "Platform", "Cafe", "Souvenir", "Convenience"). The one
-- exception is the Depart Node, authored directly under `nodesFolder` itself
-- (not inside any zone subfolder) — its implicit zone is "Depart".
function NodeGraph.GetZone(node: BasePart, nodesFolder: Instance): string
	local parent = node.Parent
	if parent == nodesFolder then
		return "Depart"
	end

	-- A "Slot Node"'s immediate parent is the "Line Node" BasePart it
	-- belongs to (the Line Node itself is a physical slot too, and lives
	-- directly in the zone folder) — go up one more level for its zone.
	if parent and parent:IsA("BasePart") and normalize(parent.Name) == "linenode" then
		parent = parent.Parent
	end

	return (parent and parent.Name) or "Depart"
end

function NodeGraph.GetZoneFolder(nodesFolder: Instance, zoneName: string): Instance?
	if zoneName == "Depart" then
		return nodesFolder
	end
	return nodesFolder:FindFirstChild(zoneName)
end

-- "node" (Basic/pass-through) | "linenode" (either a "Line Node" BasePart
-- itself — the first physical slot — or one of its "Slot Node" children, the
-- other physical slots) | normalized own name otherwise (e.g. a literal
-- "Depart Node" normalizes to "departnode").
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

-- Only ever authored on a Line Node group's main/first slot — points at the
-- separate staging point NPCs detour to before joining the line, rather than
-- approaching the queue from an arbitrary angle.
function NodeGraph.GetEntryNode(node: BasePart): BasePart?
	local entryValue = node:FindFirstChild("Entry")
	if entryValue and entryValue:IsA("ObjectValue") and entryValue.Value and entryValue.Value:IsA("BasePart") then
		return entryValue.Value :: BasePart
	end
	return nil
end

-- Authored only on a "Seat Node" BasePart — points at the physical Seat
-- instance the NPC should actually sit in on arrival (see NpcService.Local.OnArrive),
-- rather than just standing at the node's position like any other node.
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

-- All nodes belonging to `zoneName`: ordinary BaseParts directly in the zone
-- folder, plus every "Slot Node" nested under any "Line Node" BasePart
-- within it (their own Parent is the Line Node, not the zone folder, so a
-- shallow scan alone wouldn't find them).
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

-- Every node in the whole graph, regardless of zone — used for the one-time
-- "which node is nearest my spawn point" pick.
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

-- A plain "Node" is just a general waypoint, not a precise mark — spread
-- arrivals across a small area so the crowd doesn't all funnel through the
-- exact same point. Every other node type keeps its canonical position.
function NodeGraph.GetMovementTargetPosition(node: BasePart, spreadRadius: number): Vector3
	local basePos = NodeGraph.GetNodePosition(node)
	if NodeGraph.GetNodeType(node) ~= "node" then
		return basePos
	end

	local angle = math.random() * math.pi * 2
	local dist = math.random() * spreadRadius
	return basePos + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
end

-- Callers running inside the brain Actor's parallel context must already be
-- synchronized before calling this (see ActorScript.server.luau) — both
-- mutating RaycastParams' properties and calling SetAttribute (used by
-- TryClaimSlot/ReleaseSlot below) require it, even for state this
-- Actor exclusively owns.
function NodeGraph.HasClearLine(fromPos: Vector3, toPos: Vector3, ignore: { Instance? }): boolean
	local direction = toPos - fromPos
	if direction.Magnitude < 0.05 then return true end

	RAYCAST_PARAMS.FilterDescendantsInstances = ignore :: { Instance }
	local result = Workspace:Raycast(fromPos, direction, RAYCAST_PARAMS)
	return result == nil
end

-- [[ Auto-search ]] --

-- Nearest eligible node across the given zone pool. Excludes `exclude`d
-- parts, any Entry Node (those are only ever reached via the deliberate
-- pre-line detour, never picked as an ordinary fallback), and — when
-- `avoidLinkBackTo` is set (the caller just arrived here via a deterministic
-- Link hop) — any candidate whose own Link would immediately send the NPC
-- straight back, preventing a two-node oscillation.
--
-- `towardGoal`, when given, changes the ranking metric from "closest to
-- fromPos" to "closest to towardGoal" — and only among candidates strictly
-- closer to it than fromPos already is. A tightly-packed cluster of nodes
-- with no Links between them has no inherent direction, so plain
-- nearest-to-self search can bounce between the same few nodes forever;
-- ranking by progress toward a fixed goal instead guarantees it can't.
--
-- `awayFromPos`, when given instead (mutually exclusive with `towardGoal` in
-- practice — there's no fixed goal to rank toward yet), keeps plain
-- nearest-to-self ranking but rejects any candidate that isn't net farther
-- from `awayFromPos` than fromPos already is — a lighter no-backtracking
-- guarantee for when there's nothing to aim at other than "not where I just
-- came from."
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
			if distance < bestDist and NodeGraph.HasClearLine(fromPos, pos, ignore) then
				bestDist = distance
				best = node
			end
		end
	end

	return best
end

-- The canonical Depart Node's position, if one exists — Linear's backbone
-- always terminates here, used as the goal for FindNearestNode's towardGoal.
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

-- True only for a "Slot Node" child, not the Line Node BasePart itself.
function NodeGraph.IsSlotNode(node: BasePart): boolean
	local parent = node.Parent
	return parent ~= nil and parent:IsA("BasePart") and normalize(parent.Name) == "linenode" and normalize(node.Name) == "slotnode"
end

-- The Line Node BasePart `node`'s group belongs to (itself, if it already is one).
function NodeGraph.GetLineGroup(node: BasePart): BasePart
	if NodeGraph.IsSlotNode(node) then
		return node.Parent :: BasePart
	end
	return node
end

-- Recomputes and stamps `LineIsFull` on `lineNode` — true once it and every
-- one of its Slot Node children are Occupied. Call after any claim/release.
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

-- The open slot within `lineNode`'s own group (itself + its Slot Node
-- children) that's closest to the front — but only among slots strictly
-- closer to the front than `currentSlot` already is, so a queued NPC only
-- ever advances forward, never sideways/backward into a slot that happens to
-- be nearer its current position.
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

-- Every distinct Line Node group (main slot only, not its children) across
-- the given zones — for comparing crowding between multiple lines.
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
	return lineNode:GetAttribute("EnRouteCount") or 0
end

function NodeGraph.AddLineEnRoute(lineNode: BasePart, delta: number)
	lineNode:SetAttribute("EnRouteCount", math.max(NodeGraph.GetLineEnRouteCount(lineNode) + delta, 0))
end

-- Everyone this line is "accounting for": physically Occupied slots, plus
-- NPCs already committed to walking toward it but not yet arrived (see
-- SetEnRouteLine) — comparing just Occupied alone would let far more NPCs
-- converge on the same nearest line than it actually has room for, since
-- none of them show up as Occupied until they physically arrive.
function NodeGraph.GetLineLoad(lineNode: BasePart): number
	local occupied = NodeGraph.IsOccupied(lineNode) and 1 or 0
	for _, child in lineNode:GetChildren() do
		if child:IsA("BasePart") and normalize(child.Name) == "slotnode" and NodeGraph.IsOccupied(child) then
			occupied += 1
		end
	end
	return occupied + NodeGraph.GetLineEnRouteCount(lineNode)
end

-- Which line, if any, `npc` has already committed to walking toward but
-- hasn't arrived at yet. An ObjectValue child rather than an Attribute since
-- Attributes can't hold Instance references.
function NodeGraph.GetEnRouteLine(npc: Model): BasePart?
	local value = npc:FindFirstChild("EnRouteLine")
	if value and value:IsA("ObjectValue") and value.Value and value.Value:IsA("BasePart") then
		return value.Value :: BasePart
	end
	return nil
end

-- Moves `npc`'s commitment to `lineNode` (or clears it if nil), decrementing
-- whatever it was previously committed to and incrementing the new one —
-- keeps EnRouteCount accurate without callers having to track the diff.
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

-- Seat occupancy isn't our own bookkeeping like Line/Slot Nodes — it mirrors
-- the real Seat instance's Occupant, which the engine itself sets (covers
-- players sitting too, not just NPCs). Called once at round start per Seat
-- Node, plus live on every Occupant change (see NpcService.Local.WatchSeats).
function NodeGraph.SyncSeatOccupiedAttribute(seatNode: BasePart)
	local seat = NodeGraph.GetSeatObject(seatNode)
	seatNode:SetAttribute("Occupied", seat ~= nil and seat.Occupant ~= nil)
end

-- `Occupied` only becomes true once an NPC physically sits — the walk there
-- can take seconds, during which a second NPC's decision would still see the
-- seat as free. `Reserved` closes that gap: claimed the instant a decision
-- picks the seat (inside the same synchronized Actor call that makes
-- TryClaimSlot race-free — see ActorScript.server.luau), released once the
-- NPC actually sits (Occupied takes over as ground truth) or abandons the
-- attempt.
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

-- Redirects a freshly-resolved candidate to its Line Node's Entry Node
-- first, unless the NPC already came from that Entry Node (the deliberate
-- hop right after the detour) or is already inside the same line (ordinary
-- slot-to-slot progress). `Entry` is authored on the "Line Node" BasePart
-- itself (the first physical slot) — a "Slot Node" candidate resolves its
-- own Line Node via its Parent to find it.
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
