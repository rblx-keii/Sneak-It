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
local _zoneTransitions: { [string]: { [string]: boolean } } = {}

local function setZoneTransition(zoneA: string, zoneB: string, allowed: boolean)
	_zoneTransitions[zoneA] = _zoneTransitions[zoneA] or {}
	_zoneTransitions[zoneA][zoneB] = allowed or nil
	_zoneTransitions[zoneB] = _zoneTransitions[zoneB] or {}
	_zoneTransitions[zoneB][zoneA] = allowed or nil
end

for _, pair in NPCConfig.ZONE_ADJACENCY do
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

		if not isZoneTransitionValid(currentZone, NodeGraph.GetZone(other, ctx.nodesFolder)) then
			continue
		end

		local otherType = NodeGraph.GetNodeType(other)
		if otherType == "linenode" and NodeGraph.GetLineGroup(other):GetAttribute("LineIsFull") then continue end
		if otherType == "seatnode" and (NodeGraph.IsOccupied(other) or NodeGraph.IsSeatReserved(other)) then continue end

		local otherPos = NodeGraph.GetNodePosition(other)
		if (otherPos - originPos).Magnitude > NPCConfig.NODE_SEARCH_RADIUS then continue end
		if not NodeGraph.HasClearLineBetweenNodes(node, other, ignore) then continue end

		table.insert(candidates, other)
	end

	if #candidates == 0 then
		return nil, "Idle"
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
