-- Opt-in alternative to Linear: no backbone/zone progression, just picks a
-- uniformly random node from everything within NODE_SEARCH_RADIUS each time
-- it arrives somewhere, so it roams indefinitely instead of "always take the
-- literal nearest node" (which reads as robotic across a crowd of NPCs all
-- taking identical shortest paths).
--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)
local NodeGraph = require(script.Parent.Parent.NodeGraph)

local Wander = {}

--|| Types
export type Context = {
	npc: Model,
	nodesFolder: Instance,
	currentNode: BasePart,
	lastNode: BasePart?,
	arrivedViaLink: boolean,
	lastRestTime: number,
}

--|| MAIN ||--

function Wander.GetNextTarget(ctx: Context): (BasePart?, string)
	local node = ctx.currentNode
	local ignore = { ctx.npc, ctx.npc.Parent }

	-- Queued in a Slot Node: shuffle forward like Linear does — wandering
	-- into a line doesn't mean ignoring the people still ahead in it.
	if NodeGraph.IsSlotNode(node) then
		local lineGroup = NodeGraph.GetLineGroup(node)
		local nextSlot = NodeGraph.FindNextSlotForward(lineGroup, node)

		if nextSlot and NodeGraph.TryClaimSlot(nextSlot, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
			NodeGraph.ReleaseSlot(node)
			return nextSlot, "Queueing"
		end

		return nil, "Queueing"
	end

	local originPos = NodeGraph.GetNodePosition(node)
	local candidates: { BasePart } = {}

	for _, other in NodeGraph.EnumerateAllNodes(ctx.nodesFolder) do
		if other == node or other == ctx.lastNode then continue end
		if NodeGraph.IsEntryNode(other) then continue end

		local otherType = NodeGraph.GetNodeType(other)
		if otherType == "linenode" and NodeGraph.GetLineGroup(other):GetAttribute("LineIsFull") then continue end
		if otherType == "seatnode" and (NodeGraph.IsOccupied(other) or NodeGraph.IsSeatReserved(other)) then continue end

		local otherPos = NodeGraph.GetNodePosition(other)
		if (otherPos - originPos).Magnitude > NPCConfig.NODE_SEARCH_RADIUS then continue end
		if not NodeGraph.HasClearLine(originPos, otherPos, ignore) then continue end

		table.insert(candidates, other)
	end

	if #candidates == 0 then
		return nil, "Idle" -- nothing reachable this decision — retry next tick
	end

	local candidate = candidates[math.random(1, #candidates)]

	local redirected = NodeGraph.ResolveEntryRedirect(candidate, node)
	if redirected ~= candidate then
		candidate = redirected
	end

	if NodeGraph.GetNodeType(candidate) == "linenode" then
		if not NodeGraph.TryClaimSlot(candidate, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
			return nil, "Queueing"
		end
	elseif NodeGraph.GetNodeType(candidate) == "seatnode" then
		if not NodeGraph.TryReserveSeat(candidate) then
			return nil, "Queueing"
		end
	end

	if NodeGraph.GetNodeType(node) == "linenode" then
		NodeGraph.ReleaseSlot(node)
	end

	return candidate, "Wandering"
end

return Wander
