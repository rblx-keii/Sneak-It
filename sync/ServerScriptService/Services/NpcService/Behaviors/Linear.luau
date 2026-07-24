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

	local link = NodeGraph.GetLink(node)
	local candidate: BasePart? = link

	-- The only hop that's physically gated is the one that actually lands
	-- inside Depart — every other Link, including every hop *within*
	-- Depart's own chain once already inside, is unconditional. Checking
	-- the current node's own zone (not just the link target's) is what
	-- keeps this scoped to the entry hop only.
	local enteringDepart = candidate
		and NodeGraph.GetZone(node, ctx.nodesFolder) ~= "Depart"
		and NodeGraph.GetZone(candidate, ctx.nodesFolder) == "Depart"

	if enteringDepart and not workspace:GetAttribute("BoardingOpen") then
		candidate = nil
	end

	if candidate then
		-- Link-following.
	elseif NodeGraph.GetZone(node, ctx.nodesFolder) == "Depart" then
		-- True end of the Depart Folder's Link chain (no outgoing Link left).
		-- Auto-searching zones={"Depart"} from here would be able to match
		-- one of the chain's own earlier nodes (e.g. a gate entrance) as
		-- "nearest," walking the NPC backwards through the gate in a loop —
		-- just stop here instead.
	else
		local zone = NodeGraph.GetZone(node, ctx.nodesFolder)
		local zones = { zone }

		-- A zone's Transition Node(s) are the mandatory checkpoint before its
		-- Auto-search may consider anything in the next zone at all. Multiple
		-- Transition Nodes are supported (e.g. two gate entrances side by
		-- side) — whichever is nearest wins once close enough. A Transition
		-- Node with no Link authored yet isn't usable — treat it the same as
		-- not existing so NPCs don't get stranded walking up to a dead end.
		local linkedTransitionNodes = {}
		for _, transitionNode in NodeGraph.GetTransitionNodes(ctx.nodesFolder, zone) do
			if NodeGraph.GetLink(transitionNode) then
				table.insert(linkedTransitionNodes, transitionNode)
			end
		end
		local firstTransition = linkedTransitionNodes[1]
		local transitionLink = firstTransition and NodeGraph.GetLink(firstTransition)
		local nextZone = if transitionLink
			then NodeGraph.GetZone(transitionLink, ctx.nodesFolder)
			else nextBackboneZone(zone)

		local boardingOpen = workspace:GetAttribute("BoardingOpen") == true
		local gateStage = workspace:GetAttribute("GateStage")
		-- "Plane arrived" covers both the Arrived stage (gate still closed,
		-- door not open yet) and Boarding (door open) — NPCs should start
		-- making their way toward the gate as soon as the plane is physically
		-- there, not only once boarding has actually opened.
		local planeArrived = gateStage == "Arrived" or gateStage == "Boarding"

		-- Depart is the only zone with a physical gate; every other
		-- transition is always open once its Transition Node is reached.
		local transitionGated = nextZone == "Depart"
		local canApproachTransition = not transitionGated or planeArrived

		local isCurrentlySeated = NodeGraph.GetNodeType(node) == "seatnode"
		local skipNodeTypes = nil
		if isCurrentlySeated or workspace:GetServerTimeNow() - ctx.lastRestTime < NPCConfig.REST_COOLDOWN then
			skipNodeTypes = { seatnode = true }
		end

		if transitionGated and not planeArrived and not (skipNodeTypes and skipNodeTypes.seatnode) then
			-- No plane yet — sit and wait at a random open seat instead of
			-- idly circulating the zone.
			candidate = NodeGraph.FindRandomSeatNode(ctx.nodesFolder, zone, node, { node, ctx.lastNode }, ignore)
		end

		if not candidate and #linkedTransitionNodes > 0 and canApproachTransition then
			-- Stage 1: keep making progress within the zone toward its
			-- Transition Node(s), ranked toward the first one as a
			-- representative goal point — restricted to the current zone
			-- itself so it doesn't jump straight into the next zone from
			-- anywhere in this one.
			candidate = NodeGraph.FindNearestNode(
				ctx.nodesFolder,
				node,
				{ zone },
				{ node, ctx.lastNode },
				ignore,
				if ctx.arrivedViaLink then node else nil,
				skipNodeTypes,
				NodeGraph.GetNodePosition(firstTransition :: BasePart)
			)

			if not candidate then
				-- Stage 2: nothing in the zone is any closer to the
				-- Transition Node(s) than we already are — pick whichever
				-- one is actually nearest right now.
				candidate = NodeGraph.FindNearestTransitionNode(ctx.nodesFolder, zone, node, { node, ctx.lastNode }, ignore)
			end
		end

		if not candidate then
			-- Either no Transition Node has been authored for this zone yet,
			-- or one exists but we're not allowed to approach it yet (gated)
			-- — either way, fall back to ordinary same-zone wandering (plus
			-- the next zone too, but only if there's no Transition Node
			-- gatekeeping it) so movement doesn't stall completely.
			local fallbackZones = if #linkedTransitionNodes == 0 and nextZone and (not transitionGated or planeArrived)
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
			return nil, "Queueing" -- slot taken (by an NPC or a nearby player) — keep waiting where we are
		end
		NodeGraph.SetEnRouteLine(ctx.npc, nil) -- fulfilled — Occupied now accounts for this NPC instead
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
