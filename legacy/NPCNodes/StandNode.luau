-- Stand Node ("Stand Node" in Studio): a designated standing spot (no Sit) —
-- used for e.g. a Convenience Store's loose idle points. Pass-through if
-- already occupied, matching Seat Node's behavior.
local StandNode = {}

function StandNode.OnArrive(node: BasePart, record, npcService)
	if npcService.IsNodeOccupied(node) then
		npcService.AdvanceOrWait(record, node)
		return
	end

	npcService.StandAtNode(node, record)
end

return StandNode
