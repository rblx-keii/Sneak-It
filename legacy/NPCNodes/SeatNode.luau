-- Seat Node ("Seat Node" in Studio): sit for a random duration, then resume.
-- If already occupied, the NPC treats it as a pass-through instead of
-- waiting for it to free up.
local SeatNode = {}

function SeatNode.OnArrive(node: BasePart, record, npcService)
	if npcService.IsSeatOccupied(node) then
		npcService.AdvanceOrWait(record, node)
		return
	end

	npcService.OccupySeat(node, record)
end

return SeatNode
