-- Interaction Node ("Interaction Node" in Studio): cosmetic dwell point for
-- a Vending Machine / Inquiry Desk / Shelf / ATM — no economy/system hookup,
-- the NPC just pauses here for a bit and then resumes. Pass-through if
-- already occupied, matching Seat Node's behavior.
local InteractionNode = {}

function InteractionNode.OnArrive(node: BasePart, record, npcService)
	if npcService.IsNodeOccupied(node) then
		npcService.AdvanceOrWait(record, node)
		return
	end

	npcService.InteractAtNode(node, record)
end

return InteractionNode
