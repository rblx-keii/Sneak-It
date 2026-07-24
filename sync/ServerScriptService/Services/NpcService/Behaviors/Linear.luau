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

	if candidate then
		-- Deliberately unconditional: a Link chain inside the Depart Folder
		-- (gate entrance(s) -> ... -> dwell node) must keep advancing even
		-- if BoardingOpen flips false mid-walk — the NPC is already past the
		-- gate by the time it's standing on a linked node, so the
		-- BoardingOpen gate below (which only governs *entering* Depart from
		-- Platform) must never apply here.
	elseif NodeGraph.GetZone(node, ctx.nodesFolder) == "Depart" then
		-- True end of the Depart Folder's Link chain (no outgoing Link left).
		-- Auto-searching zones={"Depart"} from here would be able to match
		-- one of the chain's own earlier nodes (e.g. a gate entrance) as
		-- "nearest," walking the NPC backwards through the gate in a loop —
		-- just stop here instead.
	else
		local zone = NodeGraph.GetZone(node, ctx.nodesFolder)
		local nextZone = nextBackboneZone(zone)

		local boardingOpen = workspace:GetAttribute("BoardingOpen") == true
		local gateStage = workspace:GetAttribute("GateStage")
		-- "Plane arrived" covers both the Arrived stage (gate still closed,
		-- door not open yet) and Boarding (door open) — NPCs should start
		-- making their way toward the gate as soon as the plane is physically
		-- there, not only once boarding has actually opened.
		local planeArrived = gateStage == "Arrived" or gateStage == "Boarding"

		if nextZone == "Depart" and not planeArrived then
			nextZone = nil
		end

		local zones = if nextZone then { zone, nextZone } else { zone }

		local isCurrentlySeated = NodeGraph.GetNodeType(node) == "seatnode"
		local skipNodeTypes = nil
		if isCurrentlySeated or workspace:GetServerTimeNow() - ctx.lastRestTime < NPCConfig.REST_COOLDOWN then
			skipNodeTypes = { seatnode = true }
		end

		if zone == "Platform" and not planeArrived and not (skipNodeTypes and skipNodeTypes.seatnode) then
			-- No plane yet — sit and wait at a random open seat instead of
			-- idly circulating the platform.
			candidate = NodeGraph.FindRandomSeatNode(ctx.nodesFolder, "Platform", NodeGraph.GetNodePosition(node), { node, ctx.lastNode })
		end

		if not candidate then
			if planeArrived and zone == "Platform" then
				local departPos = NodeGraph.GetDepartPosition(ctx.nodesFolder)

				-- Stage 1: keep making progress across Platform toward the gate,
				-- ranked toward Depart same as before — restricted to Platform
				-- itself so it doesn't jump straight into the Depart Folder from
				-- anywhere on the platform. Starts as soon as the plane has
				-- arrived, even before the door is actually open.
				candidate = NodeGraph.FindNearestNode(
					ctx.nodesFolder,
					NodeGraph.GetNodePosition(node),
					{ "Platform" },
					{ node, ctx.lastNode },
					ignore,
					if ctx.arrivedViaLink then node else nil,
					skipNodeTypes,
					departPos
				)

				if not candidate and boardingOpen then
					-- Stage 2: no Platform node is any closer to Depart than we
					-- already are — we're at the gate threshold. Only actually
					-- cross into the Depart Folder once the door is genuinely
					-- open (BoardingOpen), not merely once the plane arrived.
					-- Pick whichever Depart Folder node is actually nearest to
					-- us right now (plain proximity, not ranked toward a single
					-- fixed point, so whichever gate node is genuinely closer
					-- wins) so the NPC walks straight through the gate.
					candidate = NodeGraph.FindNearestNode(
						ctx.nodesFolder,
						NodeGraph.GetNodePosition(node),
						{ "Depart" },
						{ node, ctx.lastNode },
						ignore,
						if ctx.arrivedViaLink then node else nil,
						skipNodeTypes
					)
				end
			else
				local lastNodePos = ctx.lastNode and NodeGraph.GetNodePosition(ctx.lastNode) or nil

				candidate = NodeGraph.FindNearestNode(
					ctx.nodesFolder,
					NodeGraph.GetNodePosition(node),
					zones,
					{ node, ctx.lastNode },
					ignore,
					if ctx.arrivedViaLink then node else nil,
					skipNodeTypes,
					nil,
					lastNodePos
				)
			end
		end

		if candidate and NodeGraph.GetNodeType(candidate) == "seatnode"
			and (NodeGraph.IsOccupied(candidate) or NodeGraph.IsSeatReserved(candidate)) then
			if math.random() < NPCConfig.SEAT_RETRY_CHANCE then
				candidate = NodeGraph.FindNearestNode(
					ctx.nodesFolder,
					NodeGraph.GetNodePosition(node),
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
					NodeGraph.GetNodePosition(node),
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
