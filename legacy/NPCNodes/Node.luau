-- Basic node ("Node" in Studio): walk to it, then proceed to the next node.
local Node = {}

function Node.OnArrive(node: BasePart, record, npcService)
	npcService.AdvanceOrWait(record, node)
end

return Node
