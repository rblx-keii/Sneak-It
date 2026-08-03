--|| References
local NodeGraph = require(script.Parent.Parent.NodeGraph)

-- Load-balanced selection among multiple parallel Transition (+ paired Conveyor) Node "lanes" leading
-- to the same destination zone — the equivalent of a map having several physical X-ray checkpoints.
local TransitionLanes = {}

--|| Variables
-- Node layout is static for a round, so pairing/grouping is computed once via Prefill (mirrors
-- NodeGraph's LoS cache) instead of re-walking every zone's nodes on every routing decision.
local _conveyorCache: { [BasePart]: BasePart | false } = {}
local _transitionForConveyor: { [BasePart]: BasePart } = {}
local _lanesCache: { [string]: { [string]: { lanes: { BasePart }, checkpoints: { BasePart } } } } = {}

--|| Private Functions

local function isForwardTransition(nodesFolder: Instance, transitionNode: BasePart): boolean
	local link = NodeGraph.GetLink(transitionNode)
	if not link then return false end
	return not NodeGraph.IsShopZone(NodeGraph.GetZone(link, nodesFolder))
end

-- Bijective nearest-pair matching so no Conveyor is shared by two Transitions; shop-bound Transitions
-- are excluded so they can't consume a Conveyor a forward gate Transition should own.
local function computeZonePairings(nodesFolder: Instance, zone: string): { [BasePart]: BasePart }
	local transitions = {}
	for _, transitionNode in NodeGraph.GetTransitionNodes(nodesFolder, zone) do
		if isForwardTransition(nodesFolder, transitionNode) then
			table.insert(transitions, transitionNode)
		end
	end

	local conveyors = {}
	for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zone) do
		if NodeGraph.IsConveyorNode(node) then
			table.insert(conveyors, node)
		end
	end

	local candidates = {}
	for _, transitionNode in transitions do
		local transitionPos = NodeGraph.GetNodePosition(transitionNode)
		for _, conveyor in conveyors do
			table.insert(candidates, {
				transition = transitionNode,
				conveyor = conveyor,
				dist = (NodeGraph.GetNodePosition(conveyor) - transitionPos).Magnitude,
			})
		end
	end

	table.sort(candidates, function(a, b) return a.dist < b.dist end)

	local claimedTransitions: { [BasePart]: boolean } = {}
	local claimedConveyors: { [BasePart]: boolean } = {}
	local result: { [BasePart]: BasePart } = {}

	for _, entry in candidates do
		if claimedTransitions[entry.transition] or claimedConveyors[entry.conveyor] then continue end
		claimedTransitions[entry.transition] = true
		claimedConveyors[entry.conveyor] = true
		result[entry.transition] = entry.conveyor
	end

	return result
end

--|| Public Functions

-- Reverse of GetNearestConveyor — the Transition uniquely paired with `conveyorNode`. Populated only
-- by Prefill (no lazy fallback, since the forward pairing is what's authoritative).
function TransitionLanes.GetPairedTransition(conveyorNode: BasePart): BasePart?
	return _transitionForConveyor[conveyorNode]
end

-- The Conveyor uniquely paired with `transitionNode`. Cache-only after Prefill; falls back to an
-- independent (non-unique) nearest-search if queried before Prefill runs.
function TransitionLanes.GetNearestConveyor(nodesFolder: Instance, zone: string, transitionNode: BasePart): BasePart?
	local cached = _conveyorCache[transitionNode]
	if cached ~= nil then
		if cached == false then return nil end
		return cached
	end

	local transitionPos = NodeGraph.GetNodePosition(transitionNode)
	local best: BasePart? = nil
	local bestDist = math.huge

	for _, node in NodeGraph.EnumerateZoneNodes(nodesFolder, zone) do
		if NodeGraph.IsConveyorNode(node) then
			local dist = (NodeGraph.GetNodePosition(node) - transitionPos).Magnitude
			if dist < bestDist then
				bestDist = dist
				best = node
			end
		end
	end

	_conveyorCache[transitionNode] = best or false

	return best
end

-- Every Transition Node in `zone` whose Link leads into `destinationZone`, paired with its checkpoint
-- (its uniquely-paired Conveyor, or the Transition itself if it has none).
function TransitionLanes.GetLanesTo(nodesFolder: Instance, zone: string, destinationZone: string): ({ BasePart }, { BasePart })
	local zoneCache = _lanesCache[zone]
	local cached = zoneCache and zoneCache[destinationZone]
	if cached then
		return cached.lanes, cached.checkpoints
	end

	local lanes = {}
	local checkpoints = {}

	for _, transitionNode in NodeGraph.GetTransitionNodes(nodesFolder, zone) do
		local link = NodeGraph.GetLink(transitionNode)
		if link and NodeGraph.GetZone(link, nodesFolder) == destinationZone then
			table.insert(lanes, transitionNode)
			table.insert(checkpoints, TransitionLanes.GetNearestConveyor(nodesFolder, zone, transitionNode) or transitionNode)
		end
	end

	_lanesCache[zone] = _lanesCache[zone] or {}
	_lanesCache[zone][destinationZone] = { lanes = lanes, checkpoints = checkpoints }

	return lanes, checkpoints
end

-- Computes and caches every Transition<->Conveyor pairing and lane grouping up front for `nodesFolder`
-- — call once per round, before any NPCs start routing, alongside NodeGraph.PrefillLoSCache.
function TransitionLanes.Prefill(nodesFolder: Instance)
	table.clear(_conveyorCache)
	table.clear(_transitionForConveyor)
	table.clear(_lanesCache)

	for _, zoneFolder in nodesFolder:GetChildren() do
		if not zoneFolder:IsA("Folder") then continue end
		local zone = zoneFolder.Name

		local pairings = computeZonePairings(nodesFolder, zone)

		for _, transitionNode in NodeGraph.GetTransitionNodes(nodesFolder, zone) do
			local conveyor = pairings[transitionNode]
			_conveyorCache[transitionNode] = conveyor or false
			if conveyor then
				_transitionForConveyor[conveyor] = transitionNode
			end

			local link = NodeGraph.GetLink(transitionNode)
			if link then
				TransitionLanes.GetLanesTo(nodesFolder, zone, NodeGraph.GetZone(link, nodesFolder))
			end
		end
	end
end

-- Picks the least-loaded lane and returns it with its checkpoint together — callers should always
-- resolve a redirect to this pair, never the bare Transition, so a reassigned lane still routes
-- through its own physical checkpoint instead of skipping it.
--
-- EnRouteCount alone ties out almost every time (it's transient, cleared the instant an NPC arrives),
-- and breaking ties by iteration order collapsed every decision onto the same first lane. Ties are now
-- broken by cumulative LaneUseCount (least-used-overall wins) so usage rotates across every lane
-- instead of favoring one; any remaining tie breaks randomly.
function TransitionLanes.GetLeastLoadedLane(lanes: { BasePart }, checkpoints: { BasePart }): (BasePart?, BasePart?)
	if #lanes == 0 then
		return nil, nil
	end

	local lowestLoad = math.huge
	for _, lane in lanes do
		local load = NodeGraph.GetTransitionEnRouteCount(lane)
		if load < lowestLoad then
			lowestLoad = load
		end
	end

	local lowestUse = math.huge
	for _, lane in lanes do
		if NodeGraph.GetTransitionEnRouteCount(lane) == lowestLoad then
			local uses = NodeGraph.GetTransitionUseCount(lane)
			if uses < lowestUse then
				lowestUse = uses
			end
		end
	end

	local tiedIndices = {}
	for i, lane in lanes do
		if NodeGraph.GetTransitionEnRouteCount(lane) == lowestLoad and NodeGraph.GetTransitionUseCount(lane) == lowestUse then
			table.insert(tiedIndices, i)
		end
	end

	local chosenIndex = tiedIndices[math.random(1, #tiedIndices)]
	local chosenLane = lanes[chosenIndex]
	NodeGraph.IncrementTransitionUseCount(chosenLane)

	return chosenLane, checkpoints[chosenIndex]
end

-- Redirects `candidate` (or its paired checkpoint) to whichever sibling lane is least loaded instead
-- of blindly committing to it — the fix for a deterministic Link chain otherwise always funneling
-- every NPC through the same checkpoint. No-ops for anything not part of a multi-lane group.
--
-- `originNode` being a Conveyor means this is resolving the EXIT out of it (its own Link, wired
-- deliberately to one gate) rather than the approach — that pairing wins outright instead of being
-- reshuffled, so NPCs riding the same belt don't fan out toward mismatched gates.
function TransitionLanes.ResolveLane(nodesFolder: Instance, zone: string, candidate: BasePart, npc: Model, originNode: BasePart?): BasePart
	local candidateTransition = candidate
	if NodeGraph.IsConveyorNode(candidate) then
		candidateTransition = _transitionForConveyor[candidate] or candidate
	end

	if not NodeGraph.IsTransitionNode(candidateTransition) then
		return candidate
	end

	local link = NodeGraph.GetLink(candidateTransition)
	if not link then
		return candidate
	end

	local destinationZone = NodeGraph.GetZone(link, nodesFolder)
	local lanes, checkpoints = TransitionLanes.GetLanesTo(nodesFolder, zone, destinationZone)

	if originNode and NodeGraph.IsConveyorNode(originNode) then
		for _, lane in lanes do
			if lane == candidateTransition then
				return candidate
			end
		end
	end

	if #lanes <= 1 then
		return candidate
	end

	local chosenTransition, chosenCheckpoint = TransitionLanes.GetLeastLoadedLane(lanes, checkpoints)
	if not chosenTransition then
		return candidate
	end

	NodeGraph.SetEnRouteTransition(npc, chosenTransition)

	-- Route to the checkpoint, not the bare Transition, so belt/bag-drop still triggers.
	return chosenCheckpoint or chosenTransition
end

return TransitionLanes
