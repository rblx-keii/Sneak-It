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
		candidate = NodeGraph.GetLink(node)
	end

	local enteringDepart = candidate
		and NodeGraph.GetZone(node, ctx.nodesFolder) ~= "Depart"
		and NodeGraph.GetZone(candidate, ctx.nodesFolder) == "Depart"

	if enteringDepart and not workspace:GetAttribute("BoardingOpen") then
		candidate = nil
	end

	if candidate then
	elseif NodeGraph.GetZone(node, ctx.nodesFolder) == "Depart" then
	else
		local zone = NodeGraph.GetZone(node, ctx.nodesFolder)
		local zones = { zone }

		local linkedTransitionNodes = {}
		local checkpointNodes = {}
		for _, transitionNode in NodeGraph.GetTransitionNodes(ctx.nodesFolder, zone) do
			if NodeGraph.GetLink(transitionNode) then
				table.insert(linkedTransitionNodes, transitionNode)
				local conveyor = NodeGraph.GetConveyorNodeForTransition(ctx.nodesFolder, zone, transitionNode)
				table.insert(checkpointNodes, conveyor or transitionNode)
			end
		end

		local chosenIndex = 1
		local chosenLoad = math.huge
		for i, transitionNode in linkedTransitionNodes do
			local load = NodeGraph.GetTransitionEnRouteCount(transitionNode)
			if load < chosenLoad then
				chosenLoad = load
				chosenIndex = i
			end
		end
		local chosenTransition = linkedTransitionNodes[chosenIndex]
		local chosenCheckpoint = checkpointNodes[chosenIndex]
		local transitionLink = chosenTransition and NodeGraph.GetLink(chosenTransition)
		local nextZone = if transitionLink
			then NodeGraph.GetZone(transitionLink, ctx.nodesFolder)
			else nextBackboneZone(zone)

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

		if not candidate and #linkedTransitionNodes > 0 and canApproachTransition then
			NodeGraph.SetEnRouteTransition(ctx.npc, chosenTransition)

			local progressExclude = { node, ctx.lastNode }
			for _, checkpoint in checkpointNodes do
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
				candidate = NodeGraph.FindNearestTransitionNode(ctx.nodesFolder, zone, node, { node, ctx.lastNode }, ignore, checkpointNodes)
			end
		end

		if not candidate then
			local fallbackZones = if #linkedTransitionNodes == 0 and nextZone and canApproachTransition
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
