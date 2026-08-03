--|| Services
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)
local NodeGraph = require(script.Parent.Parent.NodeGraph)

-- Shared line-queueing/occupancy mechanics used by any Behavior whose candidate nodes may resolve to
-- a Line or Seat Node — not itself a dispatched Behavior. Deliberately holds only the mechanical
-- primitives (advance/claim/release/dwell); routing policy (which line to join, entry redirects,
-- retry-vs-skip decisions) stays in the Behavior that owns it. Reuse target for Interaction Nodes.
local Queueing = {}

-- Already standing in a line slot — advances toward the front if the next slot forward is free.
-- Returns (nextSlot, true) on advance, (nil, true) if still stuck waiting, (nil, false) if `node`
-- isn't a slot at all (not this function's concern).
function Queueing.TryAdvance(node: BasePart): (BasePart?, boolean)
	if not NodeGraph.IsSlotNode(node) then
		return nil, false
	end

	local lineGroup = NodeGraph.GetLineGroup(node)
	local nextSlot = NodeGraph.FindNextSlotForward(lineGroup, node)

	if nextSlot and NodeGraph.TryClaimSlot(nextSlot, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
		NodeGraph.ReleaseSlot(node)
		return nextSlot, true
	end

	return nil, true
end

-- Claims a chosen candidate node once a Behavior has decided to head there. Line Node candidates
-- fall back to the nearest open slot in the same group if the exact node is taken; Seat Node
-- candidates reserve outright. Any other node type always succeeds without side effects. Returns the
-- (possibly redirected-to-a-slot) node to actually walk to, and whether the claim succeeded.
function Queueing.ClaimForArrival(candidate: BasePart): (BasePart, boolean)
	local nodeType = NodeGraph.GetNodeType(candidate)

	if nodeType == "linenode" then
		if NodeGraph.TryClaimSlot(candidate, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
			return candidate, true
		end

		local openSlot = NodeGraph.FindNearestAvailableSlot(NodeGraph.GetLineGroup(candidate))
		if openSlot and NodeGraph.TryClaimSlot(openSlot, NPCConfig.LINE_SLOT_PLAYER_RADIUS) then
			return openSlot, true
		end

		return candidate, false
	elseif nodeType == "seatnode" then
		return candidate, NodeGraph.TryReserveSeat(candidate)
	end

	return candidate, true
end

-- Releases whatever slot the NPC is leaving, if it was standing in a Line Node. No-ops otherwise.
function Queueing.Release(node: BasePart)
	if NodeGraph.GetNodeType(node) == "linenode" then
		NodeGraph.ReleaseSlot(node)
	end
end

-- Front-of-line dwell: call on arrival to get the deadline the NPC should pause at the line's main
-- slot before proceeding. Returns nil for anything that isn't a line's main slot (sub-slots dwell
-- via TryAdvance's own pacing, not this).
function Queueing.StartDwell(node: BasePart): number?
	if NodeGraph.GetNodeType(node) ~= "linenode" or NodeGraph.IsSlotNode(node) then
		return nil
	end
	return Workspace:GetServerTimeNow() + math.random(NPCConfig.LINE_DWELL_MIN, NPCConfig.LINE_DWELL_MAX)
end

function Queueing.IsDwelling(dwellUntil: number): boolean
	return dwellUntil > 0 and Workspace:GetServerTimeNow() < dwellUntil
end

return Queueing
