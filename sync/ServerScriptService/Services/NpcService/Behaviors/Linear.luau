--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)
local NodeGraph = require(script.Parent.Parent.NodeGraph)

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

--|| Private Functions
local function nextBackboneZone(zone: string): string?
	local sequence = NPCConfig.LINEAR_ZONE_SEQUENCE
	for i, z in sequence do
		if z == zone then
			return sequence[i + 1]
		end
	end
	return nil
end

-- Shop zones (Cafe/Souvenir/Convenience) branch off the backbone and have no "next" of their
-- own in LINEAR_ZONE_SEQUENCE — once a shop-dwell expires back to Linear, this is what lets
-- GetNextTarget find its way back out via whichever zone it's adjacent to (always Concourse).
local function resolveNextZone(zone: string): string?
	local backboneNext = nextBackboneZone(zone)
	if backboneNext then
		return backboneNext
	end

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

-- Linked Transition Nodes in a zone, split by where they actually lead: "forward" ones continue
-- the Lobby->Concourse->Platform->Depart backbone, "shop" ones detour into a side zone. Blending
-- both into one load-balancing pool used to silently divert backbone traffic into shops with no
-- real decision behind it — Concourse Loitering is that decision.
local function buildTransitionPools(nodesFolder: Instance, zone: string, nextZone: string?): (
	{ BasePart },
	{ BasePart },
	{ [string]: { BasePart } }
)
	local forwardTransitions = {}
	local forwardCheckpoints = {}
	local shopTransitionsByZone: { [string]: { BasePart } } = {}

	for _, transitionNode in NodeGraph.GetTransitionNodes(nodesFolder, zone) do
		local link = NodeGraph.GetLink(transitionNode)
		if not link then continue end

		local linkZone = NodeGraph.GetZone(link, nodesFolder)
		if linkZone == nextZone then
			table.insert(forwardTransitions, transitionNode)
			local conveyor = NodeGraph.GetConveyorNodeForTransition(nodesFolder, zone, transitionNode)
			table.insert(forwardCheckpoints, conveyor or transitionNode)
		else
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
		local lineGroup = NodeGraph.GetLineGroup(node)
		local nextSlot = NodeGraph.FindNextSlotForward(lineGroup, node)

		if nextSlot and NodeGraph.TryClaimSlot(nextSlot, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
			NodeGraph.ReleaseSlot(node)
			return nextSlot, "Queueing"
		end

		return nil, "Queueing"
	end

	local candidate: BasePart?

	if NodeGraph.IsEntryNode(node) then
		candidate = NodeGraph.GetLineNodeForEntry(ctx.nodesFolder, NodeGraph.GetZone(node, ctx.nodesFolder), node)
	elseif NodeGraph.GetNodeType(node) == "seatnode" then
		candidate = nil
	else
		-- Shop entry/exit is the same Transition Node <-> Transition Node link walked in both
		-- directions, so a node just arrived at via link would otherwise immediately re-follow
		-- its own Link straight back the way it came (e.g. bouncing right back into a shop it
		-- just left). Suppress that one case and let the dispatch below find real forward
		-- progress instead; any other Link target is still taken as normal.
		local link = NodeGraph.GetLink(node)
		candidate = if link ~= ctx.lastNode then link else nil
	end

	local zone = NodeGraph.GetZone(node, ctx.nodesFolder)

	local enteringDepart = candidate
		and zone ~= "Depart"
		and NodeGraph.GetZone(candidate, ctx.nodesFolder) == "Depart"

	if enteringDepart and not workspace:GetAttribute("BoardingOpen") then
		candidate = nil
	end

	-- Concourse Loitering: once per visit, a Concourse NPC may detour into a shop, wander the
	-- Concourse floor itself, or sit down, instead of always making straight-line progress toward
	-- Platform — bag-holders included, since this is crowd flavor (the belt-riding bag is just a
	-- visual prop, not the player Smuggler/TSA game) and can afford to take the scenic route.
	-- Evaluated here — before the Link-based dispatch below — because a "Node" with an authored
	-- fixed Link (used to shape the walking path through Concourse) would otherwise always win
	-- outright and the roll would never get a chance to fire. Rolled once via the
	-- ConcourseLoiterRolled attribute (cleared in NpcService.OnArrive on leaving Concourse).
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
			-- roll >= seatThreshold falls into the remaining slice: keep heading toward the next zone anyway

			local wantsWander = false

			if roll < shopThreshold then
				local _, _, shopTransitionsByZone = buildTransitionPools(ctx.nodesFolder, zone, nextBackboneZone(zone))
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
			-- else: Forward — no override, the existing Link/forward-progress dispatch wins as usual

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

		local chosenIndex = 1
		local chosenLoad = math.huge
		for i, transitionNode in forwardTransitions do
			local load = NodeGraph.GetTransitionEnRouteCount(transitionNode)
			if load < chosenLoad then
				chosenLoad = load
				chosenIndex = i
			end
		end
		local chosenTransition = forwardTransitions[chosenIndex]
		local chosenCheckpoint = forwardCheckpoints[chosenIndex]

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

		if not candidate and ctx.holdingBag then
			local nearbyConveyors =
				NodeGraph.GetNodesInZone(ctx.nodesFolder, { zone }, NodeGraph.GetNodePosition(node), false, { "conveyornode" })

			for _, conveyor in nearbyConveyors do
				if (NodeGraph.GetNodePosition(conveyor) - NodeGraph.GetNodePosition(node)).Magnitude > NPCConfig.NODE_SEARCH_RADIUS then
					break
				end
				if NodeGraph.HasClearLineBetweenNodes(node, conveyor, ignore) then
					candidate = conveyor
					break
				end
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

			if not candidate then
				candidate = NodeGraph.FindNearestTransitionNode(ctx.nodesFolder, zone, node, { node, ctx.lastNode }, ignore, forwardCheckpoints)
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

	if NodeGraph.GetNodeType(candidate) == "linenode" then
		if not NodeGraph.TryClaimSlot(candidate, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
			local openSlot = NodeGraph.FindNearestAvailableSlot(NodeGraph.GetLineGroup(candidate))
			if not openSlot or not NodeGraph.TryClaimSlot(openSlot, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
				return nil, "Queueing"
			end
			candidate = openSlot
		end
		NodeGraph.SetEnRouteLine(ctx.npc, nil)
	elseif NodeGraph.GetNodeType(candidate) == "seatnode" then
		if not NodeGraph.TryReserveSeat(candidate) then
			return nil, "Queueing"
		end
	end

	if NodeGraph.GetNodeType(node) == "linenode" then
		NodeGraph.ReleaseSlot(node)
	end

	return candidate, "Commuting"
end

return Linear
