-- Conveyor Node ("Conveyor Node" in Studio): drop the held bag onto the belt
-- (it travels to the paired exit node — the node's Link — independently of
-- the NPC) and keep walking through the checkpoint.
local ConveyorNode = {}

function ConveyorNode.OnArrive(node: BasePart, record, npcService)
	npcService.StartConveyorTransit(node, record)
end

return ConveyorNode
