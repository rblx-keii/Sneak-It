-- The first Behavior module: no traits, no detours — just walks the fixed
-- backbone zone sequence (Lobby -> Concourse -> Platform -> Depart) straight
-- through, joining/advancing through Line Nodes along the way as needed.
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

-- Returns the next node to walk to (nil = blocked/retry-later, e.g. waiting
-- on a full Line Node, or a genuine dead end at Depart — both just mean "no
-- target this tick") plus a debug-visible state label mirrored onto the
-- NPC's `AIState` attribute by the caller.
function Linear.GetNextTarget(ctx: Context): (BasePart?, string)
	local node = ctx.currentNode
	local ignore = { ctx.npc, ctx.npc.Parent }

	local function debugWarn(message: string)
		warn(`[NPC {ctx.npc:GetAttribute("UID") or ctx.npc.Name}] [Linear] {message}`)
	end

	-- Queued in a Slot Node: always shuffle forward within the same line
	-- before considering anything else — never leapfrogs out to another node.
	if NodeGraph.IsSlotNode(node) then
		local lineGroup = NodeGraph.GetLineGroup(node)
		local nextSlot = NodeGraph.FindNextSlotForward(lineGroup, node)

		if nextSlot and NodeGraph.TryClaimSlot(nextSlot, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
			NodeGraph.ReleaseSlot(node)
			debugWarn(`advancing in line: {node.Name} -> {nextSlot.Name}`)
			return nextSlot, "Queueing"
		end

		return nil, "Queueing"
	end

	local link = NodeGraph.GetLink(node)
	local candidate: BasePart? = link

	if candidate then
		debugWarn(`{node.Name} has a Link -> {candidate.Name}`)
	else
		local zone = NodeGraph.GetZone(node, ctx.nodesFolder)
		local nextZone = nextBackboneZone(zone)

		-- Platform -> Depart is gated on boarding actually being open — an
		-- NPC waiting on the platform shouldn't route toward the plane at
		-- all until then, rather than walking over and idling at Depart.
		if nextZone == "Depart" and not workspace:GetAttribute("BoardingOpen") then
			nextZone = nil
		end

		local zones = if nextZone then { zone, nextZone } else { zone }

		debugWarn(`{node.Name} (zone {zone}) has no Link — Auto-searching zone(s) [{table.concat(zones, ", ")}]`)

		-- Skip Seat Node candidates entirely while the NPC is still within its
		-- rest cooldown, so a fresh decision doesn't just walk it right back to
		-- another seat immediately after standing up. LastRestTime only
		-- updates once the NPC actually stands (see NpcService.Local.WalkTo),
		-- so it can't yet reflect a rest that's still in progress — being
		-- currently seated IN a Seat Node counts as "within cooldown" too,
		-- otherwise the very decision that stands the NPC up could target a
		-- second Seat Node before LastRestTime ever gets updated.
		local isCurrentlySeated = NodeGraph.GetNodeType(node) == "seatnode"
		local skipNodeTypes = nil
		if isCurrentlySeated or workspace:GetServerTimeNow() - ctx.lastRestTime < NPCConfig.REST_COOLDOWN then
			skipNodeTypes = { seatnode = true }
		end

		-- While boarding's open, rank toward the Depart Node instead of
		-- purely by proximity — plain nearest-to-self search has no sense of
		-- progress, so a tightly-packed cluster of nodes with no Links
		-- between them (e.g. right after a checkpoint) can end up bouncing
		-- between the same few candidates indefinitely instead of moving on.
		-- Otherwise there's no fixed goal to aim at yet (Depart isn't even
		-- reachable — see the zone gating above), so fall back to plain
		-- nearest-to-self, but still refuse anything that isn't net farther
		-- from wherever the NPC just came from, for the same reason.
		local boardingOpen = workspace:GetAttribute("BoardingOpen") == true
		local departPos = if boardingOpen then NodeGraph.GetDepartPosition(ctx.nodesFolder) else nil
		local lastNodePos = (not departPos) and ctx.lastNode and NodeGraph.GetNodePosition(ctx.lastNode) or nil

		candidate = NodeGraph.FindNearestNode(
			ctx.nodesFolder,
			NodeGraph.GetNodePosition(node),
			zones,
			{ node, ctx.lastNode },
			ignore,
			if ctx.arrivedViaLink then node else nil,
			skipNodeTypes,
			departPos,
			lastNodePos
		)

		debugWarn(`Auto-search result: {candidate and candidate.Name or "NONE"}`)

		-- Landed on an already-occupied (or already-reserved by another NPC's
		-- in-flight decision) Seat Node: roll whether to keep looking for a
		-- different open seat, or give up on sitting and continue on toward
		-- boarding instead.
		if candidate and NodeGraph.GetNodeType(candidate) == "seatnode"
			and (NodeGraph.IsOccupied(candidate) or NodeGraph.IsSeatReserved(candidate)) then
			if math.random() < NPCConfig.SEAT_RETRY_CHANCE then
				debugWarn(`{candidate.Name} is occupied — still want to sit, looking for another seat`)
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
				debugWarn(`{candidate.Name} is occupied — giving up on sitting, continuing on`)
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

			debugWarn(`re-search result: {candidate and candidate.Name or "NONE"}`)
		end

		-- Landed on a Line Node for the first time (not already staged at its
		-- Entry Node, which is handled once it's actually there): compare it
		-- against every other line group in range and prefer whichever is
		-- least loaded, unless that one's meaningfully farther, in which case
		-- roll whether to just wait at the nearer, busier one instead.
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

				if tooFar and math.random() < NPCConfig.LINE_PREFER_NEAREST_CHANCE then
					debugWarn(`{bestLine.Name} is less crowded (load {bestLoad}) but too far — staying with nearest {nearestLine.Name}`)
				else
					debugWarn(`preferring less-crowded line {bestLine.Name} (load {bestLoad}) over nearest {nearestLine.Name}`)
					candidate = bestLine
				end
			end

			NodeGraph.SetEnRouteLine(ctx.npc, NodeGraph.GetLineGroup(candidate :: BasePart))
		end
	end

	if not candidate then
		return nil, "Arrived"
	end

	local redirected = NodeGraph.ResolveEntryRedirect(candidate, node)
	if redirected ~= candidate then
		debugWarn(`redirecting to Entry Node {redirected.Name} before joining {candidate.Name}`)
		candidate = redirected
	end

	if NodeGraph.GetNodeType(candidate) == "linenode" then
		local claimed = NodeGraph.TryClaimSlot(candidate, NPCConfig.LINE_SLOT_PLAYER_RADIUS)
		debugWarn(`line slot {candidate.Name} claim {if claimed then "SUCCEEDED" else "FAILED (occupied/nearby player)"}`)
		if not claimed then
			return nil, "Queueing" -- slot taken (by an NPC or a nearby player) — keep waiting where we are
		end
		NodeGraph.SetEnRouteLine(ctx.npc, nil) -- fulfilled — Occupied now accounts for this NPC instead
	elseif NodeGraph.GetNodeType(candidate) == "seatnode" then
		-- Reserve it now, inside this same synchronized decision — the actual
		-- claim moment, closing the race window a second NPC's decision could
		-- otherwise slip into while this one is still walking over.
		if not NodeGraph.TryReserveSeat(candidate) then
			return nil, "Queueing"
		end
	end

	-- Only release the slot we're currently standing in once we've actually
	-- secured somewhere to go — releasing earlier would let another NPC/
	-- player claim it while we're still physically standing there.
	if NodeGraph.GetNodeType(node) == "linenode" then
		NodeGraph.ReleaseSlot(node)
	end

	return candidate, "Commuting"
end

return Linear
