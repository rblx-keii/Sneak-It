--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)
local NodeGraph = require(script.Parent.Parent.NodeGraph)
local Queueing = require(script.Parent.Queueing)
local TransitionLanes = require(script.Parent.TransitionLanes)

local Linear = {}

--|| Types
export type Context = {
	npc: Model,
	nodesFolder: Instance,
	currentNode: BasePart,
	lastNode: BasePart?,
	arrivedViaLink: boolean,
	lastRestTime: number,
	willBoard: boolean?,
	holdingBag: boolean?,
	pendingBagNode: BasePart?,
}

--|| Constants
-- Linear's only goal for now — the single fixed endpoint every Crowd NPC eventually commutes
-- toward. NodeGraph.FindZoneRoute is goal-agnostic, though: a future trait/Behavior can call it with
-- a different goal zone (a ticket counter, a specific shop) without needing a new routing mechanism.
local GOAL_ZONE = "Depart"

--|| Private Functions

-- Pre-defines *which zone to head toward next* via a real BFS route to the goal zone (replaces the
-- old hardcoded LINEAR_ZONE_SEQUENCE array) — shop zones (Cafe/Souvenir/Convenience) fall out of this
-- naturally instead of needing a separate fallback, since the route from any of them back toward the
-- goal always passes through Concourse. Only shapes the route's shape; NodeGraph.FindNearestNode and
-- the rest of GetNextTarget still make every actual node-level pick live (load, occupancy, retries).
local function resolveNextZone(zone: string): string?
	if zone == GOAL_ZONE then
		return nil
	end

	local route = NodeGraph.FindZoneRoute(zone, GOAL_ZONE)
	if route and #route >= 2 then
		return route[2]
	end

	-- Goal unreachable via adjacency from here (shouldn't happen with a well-formed
	-- NPCConfig.ZONE_ADJACENCY) — fail soft to any neighboring zone rather than stranding the NPC.
	for _, pair in NPCConfig.ZONE_ADJACENCY do
		if pair[1] == zone then
			return pair[2]
		elseif pair[2] == zone then
			return pair[1]
		end
	end
	return nil
end

-- Weighted pick among the canonical shop zones — flat by default (NPCConfig.SHOP_PICK_WEIGHTS),
-- boosted toward Cafe for Caffeinated NPCs. Picked up front so a shop-detour roll commits to one
-- destination rather than implicitly favoring whichever shop iterates first/nearest.
local function pickShopZone(npc: Model): string
	local weights: { [string]: number } = {}
	local total = 0

	for _, shopZone in NPCConfig.SHOP_ZONES do
		local weight = NPCConfig.SHOP_PICK_WEIGHTS[shopZone] or 1
		if shopZone == "Cafe" and npc:GetAttribute("Caffeinated") == true then
			weight *= NPCConfig.CAFFEINATED_CAFE_WEIGHT_MULTIPLIER
		end
		weights[shopZone] = weight
		total += weight
	end

	local roll = math.random() * total
	for _, shopZone in NPCConfig.SHOP_ZONES do
		roll -= weights[shopZone]
		if roll <= 0 then
			return shopZone
		end
	end
	return NPCConfig.SHOP_ZONES[#NPCConfig.SHOP_ZONES]
end

-- Linked Transition Nodes in a zone, split by where they lead: "forward" ones continue the backbone,
-- "shop" ones detour into a side zone (picked deliberately via Concourse Loitering, not by accident).
-- Forward lanes/checkpoints are pulled straight from TransitionLanes.GetLanesTo — the same cached
-- pairing ResolveLane uses — instead of independently rebuilding the pairing here, so there's exactly
-- one source of truth for "what's this Transition's checkpoint."
local function buildTransitionPools(nodesFolder: Instance, zone: string, nextZone: string?): (
	{ BasePart },
	{ BasePart },
	{ [string]: { BasePart } }
)
	local forwardTransitions, forwardCheckpoints = {}, {}
	if nextZone then
		forwardTransitions, forwardCheckpoints = TransitionLanes.GetLanesTo(nodesFolder, zone, nextZone)
	end

	local shopTransitionsByZone: { [string]: { BasePart } } = {}

	for _, transitionNode in NodeGraph.GetTransitionNodes(nodesFolder, zone) do
		local link = NodeGraph.GetLink(transitionNode)
		if not link then continue end

		local linkZone = NodeGraph.GetZone(link, nodesFolder)
		if linkZone ~= nextZone then
			shopTransitionsByZone[linkZone] = shopTransitionsByZone[linkZone] or {}
			table.insert(shopTransitionsByZone[linkZone], transitionNode)
		end
	end

	return forwardTransitions, forwardCheckpoints, shopTransitionsByZone
end

--|| MAIN ||--

function Linear.GetNextTarget(ctx: Context): (BasePart?, string)
	local node = ctx.currentNode
	local ignore = { ctx.npc, ctx.npc.Parent }

	if NodeGraph.IsSlotNode(node) then
		local nextSlot = Queueing.TryAdvance(node)
		return nextSlot, "Queueing"
	end

	local candidate: BasePart?

	if NodeGraph.IsEntryNode(node) then
		candidate = NodeGraph.GetLineNodeForEntry(ctx.nodesFolder, NodeGraph.GetZone(node, ctx.nodesFolder), node)
	elseif NodeGraph.GetNodeType(node) == "seatnode" then
		candidate = nil
	else
		local link = NodeGraph.GetLink(node)
		candidate = if link ~= ctx.lastNode then link else nil
	end

	local zone = NodeGraph.GetZone(node, ctx.nodesFolder)

	if candidate then
		candidate = TransitionLanes.ResolveLane(ctx.nodesFolder, zone, candidate, ctx.npc, node)
	end

	local enteringDepart = candidate
		and zone ~= "Depart"
		and NodeGraph.GetZone(candidate, ctx.nodesFolder) == "Depart"

	if enteringDepart and not workspace:GetAttribute("BoardingOpen") then
		candidate = nil
	end

	if zone == "Concourse"
		and NodeGraph.GetNodeType(node) == "node"
		and not ctx.npc:GetAttribute("ConcourseLoiterRolled")
	then
		ctx.npc:SetAttribute("ConcourseLoiterRolled", true)

		if math.random() < NPCConfig.CONCOURSE_LOITER_CHANCE then
			local loiterCandidate: BasePart? = nil
			local roll = math.random()

			local shopThreshold = NPCConfig.CONCOURSE_LOITER_SHOP_WEIGHT
			local wanderThreshold = shopThreshold + NPCConfig.CONCOURSE_LOITER_WANDER_WEIGHT
			local seatThreshold = wanderThreshold + NPCConfig.CONCOURSE_LOITER_SEAT_WEIGHT

			local wantsWander = false

			if roll < shopThreshold then
				local _, _, shopTransitionsByZone = buildTransitionPools(ctx.nodesFolder, zone, resolveNextZone(zone))
				local pickedPool = shopTransitionsByZone[pickShopZone(ctx.npc)]

				if pickedPool then
					loiterCandidate = NodeGraph.FindNearestTransitionNode(ctx.nodesFolder, zone, node, { node, ctx.lastNode }, ignore, pickedPool)
				end
				wantsWander = not loiterCandidate
			elseif roll < wanderThreshold then
				wantsWander = true
			elseif roll < seatThreshold then
				loiterCandidate = NodeGraph.FindRandomSeatNode(ctx.nodesFolder, zone, node, { node, ctx.lastNode }, ignore)
				wantsWander = not loiterCandidate
			end
			if wantsWander then
				loiterCandidate = NodeGraph.FindNearestNode(ctx.nodesFolder, node, { zone }, { node, ctx.lastNode }, ignore)
				if loiterCandidate then
					ctx.npc:SetAttribute("PendingConcourseLoiterWander", true)
				end
			end

			if loiterCandidate then
				candidate = loiterCandidate
			end
		end
	end

	if candidate then
	elseif zone == "Depart" then
	else
		local zones = { zone }
		local nextZone = resolveNextZone(zone)
		local forwardTransitions, forwardCheckpoints, shopTransitionsByZone = buildTransitionPools(ctx.nodesFolder, zone, nextZone)

		local chosenTransition: BasePart? = NodeGraph.GetEnRouteTransition(ctx.npc)
		local chosenCheckpoint: BasePart? = nil
		if chosenTransition then
			for i, transitionNode in forwardTransitions do
				if transitionNode == chosenTransition then
					chosenCheckpoint = forwardCheckpoints[i]
					break
				end
			end
			if not chosenCheckpoint then
				chosenTransition = nil
			end
		end
		if not chosenTransition then
			chosenTransition, chosenCheckpoint = TransitionLanes.GetLeastLoadedLane(forwardTransitions, forwardCheckpoints)
		end

		local boardingOpen = workspace:GetAttribute("BoardingOpen") == true
		local gateStage = workspace:GetAttribute("GateStage")
		local planeArrived = gateStage == "Arrived" or gateStage == "Boarding"

		local transitionGated = nextZone == "Depart"
		local canApproachTransition = not transitionGated or (planeArrived and ctx.willBoard == true)

		local isCurrentlySeated = NodeGraph.GetNodeType(node) == "seatnode"
		local skipNodeTypes = nil
		if isCurrentlySeated or workspace:GetServerTimeNow() - ctx.lastRestTime < NPCConfig.REST_COOLDOWN then
			skipNodeTypes = { seatnode = true }
		end

		if ctx.arrivedViaLink and ctx.lastNode and NodeGraph.IsTransitionNode(ctx.lastNode) then
			if ctx.pendingBagNode and NodeGraph.GetZone(ctx.pendingBagNode, ctx.nodesFolder) == zone then
				candidate = ctx.pendingBagNode
			else
				candidate = NodeGraph.FindNearestPickupNode(ctx.nodesFolder, zone, node, ignore)
			end
		end

		if not candidate and isCurrentlySeated then
			local sorted = NodeGraph.GetNodesInZone(ctx.nodesFolder, { zone }, NodeGraph.GetNodePosition(node), true, { "seatnode" })

			local nearestOverall: BasePart? = nil
			for _, sortedNode in sorted do
				if sortedNode == node or sortedNode == ctx.lastNode then continue end
				nearestOverall = nearestOverall or sortedNode
				if NodeGraph.HasClearLineBetweenNodes(node, sortedNode, ignore) then
					candidate = sortedNode
					break
				end
			end

			if not candidate and nearestOverall then
				local bridgeCandidates: { BasePart } = {}
				for _, sortedNode in sorted do
					if sortedNode ~= nearestOverall then
						table.insert(bridgeCandidates, sortedNode)
					end
				end
				candidate = NodeGraph.FindLoSBridge(ctx.nodesFolder, node, nearestOverall, ignore, bridgeCandidates)
			end

			if not candidate then
				candidate = NodeGraph.FindNearestNode(ctx.nodesFolder, node, { zone }, { node, ctx.lastNode }, ignore)
			end
		end

		if not candidate and transitionGated and not canApproachTransition and not (skipNodeTypes and skipNodeTypes.seatnode) then
			candidate = NodeGraph.FindRandomSeatNode(ctx.nodesFolder, zone, node, { node, ctx.lastNode }, ignore)
		end

		if not candidate and #forwardTransitions > 0 and canApproachTransition then
			NodeGraph.SetEnRouteTransition(ctx.npc, chosenTransition)

			local progressExclude = { node, ctx.lastNode }
			for _, checkpoint in forwardCheckpoints do
				table.insert(progressExclude, checkpoint)
			end

			candidate = NodeGraph.FindNearestNode(
				ctx.nodesFolder,
				node,
				{ zone },
				progressExclude,
				ignore,
				if ctx.arrivedViaLink then node else nil,
				skipNodeTypes,
				NodeGraph.GetNodePosition(chosenCheckpoint :: BasePart)
			)

			if candidate and NodeGraph.IsTransitionNode(candidate) then
				candidate = nil
			end

			if not candidate then
				if NodeGraph.HasClearLineBetweenNodes(node, chosenCheckpoint :: BasePart, ignore) then
					candidate = chosenCheckpoint
				else
					candidate = NodeGraph.FindLoSBridge(ctx.nodesFolder, node, chosenCheckpoint :: BasePart, ignore)
				end
			end
		end

		if not candidate then
			local fallbackZones = if #forwardTransitions == 0 and nextZone and canApproachTransition
				then { zone, nextZone }
				else { zone }
			local lastNodePos = ctx.lastNode and NodeGraph.GetNodePosition(ctx.lastNode) or nil

			candidate = NodeGraph.FindNearestNode(
				ctx.nodesFolder,
				node,
				fallbackZones,
				{ node, ctx.lastNode },
				ignore,
				if ctx.arrivedViaLink then node else nil,
				skipNodeTypes,
				nil,
				lastNodePos
			)
		end

		if candidate and NodeGraph.GetNodeType(candidate) == "seatnode"
			and (NodeGraph.IsOccupied(candidate) or NodeGraph.IsSeatReserved(candidate)) then
			if math.random() < NPCConfig.SEAT_RETRY_CHANCE then
				candidate = NodeGraph.FindNearestNode(
					ctx.nodesFolder,
					node,
					zones,
					{ node, ctx.lastNode, candidate },
					ignore,
					if ctx.arrivedViaLink then node else nil,
					skipNodeTypes
				)
			else
				local skipSeats = skipNodeTypes or {}
				skipSeats.seatnode = true
				candidate = NodeGraph.FindNearestNode(
					ctx.nodesFolder,
					node,
					zones,
					{ node, ctx.lastNode },
					ignore,
					if ctx.arrivedViaLink then node else nil,
					skipSeats
				)
			end
		end

		if candidate and NodeGraph.GetNodeType(candidate) == "linenode" and not NodeGraph.IsEntryNode(node) then
			local nearestLine = NodeGraph.GetLineGroup(candidate)
			local bestLine = nearestLine
			local bestLoad = NodeGraph.GetLineLoad(nearestLine)
			local originPos = NodeGraph.GetNodePosition(node)
			local nearestDist = (NodeGraph.GetNodePosition(nearestLine) - originPos).Magnitude

			for _, otherLine in NodeGraph.EnumerateLineGroups(ctx.nodesFolder, zones) do
				if otherLine == nearestLine or otherLine:GetAttribute("LineIsFull") then continue end

				local load = NodeGraph.GetLineLoad(otherLine)
				if load < bestLoad then
					bestLoad = load
					bestLine = otherLine
				end
			end

			if bestLine ~= nearestLine then
				local bestDist = (NodeGraph.GetNodePosition(bestLine) - originPos).Magnitude
				local tooFar = (bestDist - nearestDist) > NPCConfig.LINE_PREFER_NEAREST_DISTANCE_THRESHOLD

				if not (tooFar and math.random() < NPCConfig.LINE_PREFER_NEAREST_CHANCE) then
					candidate = bestLine
				end
			end

			NodeGraph.SetEnRouteLine(ctx.npc, NodeGraph.GetLineGroup(candidate :: BasePart))
		end
	end

	if not candidate then
		return nil, "Arrived"
	end

	candidate = NodeGraph.ResolveEntryRedirect(candidate, node)

	local isLineCandidate = NodeGraph.GetNodeType(candidate) == "linenode"
	local claimed: boolean
	candidate, claimed = Queueing.ClaimForArrival(candidate)
	if not claimed then
		return nil, "Queueing"
	end
	if isLineCandidate then
		NodeGraph.SetEnRouteLine(ctx.npc, nil)
	end

	Queueing.Release(node)

	return candidate, "Commuting"
end

return Linear
