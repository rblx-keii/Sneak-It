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

--|| Variables
-- Zone pairs Wander is currently allowed to cross between, seeded from the
-- map's fixed structural adjacency (NPCConfig.ZONE_ADJACENCY) and mutable at
-- runtime — e.g. GateService can close the Platform/Depart pair while the
-- gate is shut so a Wandering NPC can't step through it, then reopen it.
local _zoneTransitions: { [string]: { [string]: boolean } } = {}

local function setZoneTransition(zoneA: string, zoneB: string, allowed: boolean)
	_zoneTransitions[zoneA] = _zoneTransitions[zoneA] or {}
	_zoneTransitions[zoneA][zoneB] = allowed or nil
	_zoneTransitions[zoneB] = _zoneTransitions[zoneB] or {}
	_zoneTransitions[zoneB][zoneA] = allowed or nil
end

for _, pair in NPCConfig.ZONE_ADJACENCY do
	-- Depart is gate-only territory: the sole legal way in is Linear's
	-- explicit two-stage Platform->Depart search (see Linear.luau), never a
	-- Wander roll. Skipping this pair here doesn't block wandering *within*
	-- Depart once already there (same-zone is always valid, see below) — it
	-- only stops Wander from treating the gate itself as crossable.
	if pair[1] == "Depart" or pair[2] == "Depart" then continue end
	setZoneTransition(pair[1], pair[2], true)
end

local function isZoneTransitionValid(zoneA: string, zoneB: string): boolean
	if zoneA == zoneB then return true end
	return _zoneTransitions[zoneA] ~= nil and _zoneTransitions[zoneA][zoneB] == true
end

--|| Public API

function Wander.AddZoneTransition(zoneA: string, zoneB: string)
	setZoneTransition(zoneA, zoneB, true)
end

function Wander.RemoveZoneTransition(zoneA: string, zoneB: string)
	setZoneTransition(zoneA, zoneB, false)
end

--|| MAIN ||--

function Wander.GetNextTarget(ctx: Context): (BasePart?, string)
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

	local originPos = NodeGraph.GetNodePosition(node)
	local currentZone = NodeGraph.GetZone(node, ctx.nodesFolder)
	local candidates: { BasePart } = {}

	for _, other in NodeGraph.EnumerateAllNodes(ctx.nodesFolder) do
		if other == node or other == ctx.lastNode then continue end
		if NodeGraph.IsEntryNode(other) then continue end

		-- Stay confined to the current zone unless the pair (currentZone,
		-- other's zone) is a currently-open transition — crossing into it
		-- re-anchors "current zone" to wherever it lives for the next
		-- decision, so movement naturally stays confined there.
		if not isZoneTransitionValid(currentZone, NodeGraph.GetZone(other, ctx.nodesFolder)) then
			continue
		end

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
