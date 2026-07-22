-- Line Node ("Line Node" in Studio): join the FIFO queue at this node.
-- Advancing past the front of the line is handled centrally by
-- NPCAIService's line-dwell timer, not here.
local LineNode = {}

function LineNode.OnArrive(node: BasePart, record, npcService)
	npcService.SetState(record, "Queueing")
	npcService.JoinLineQueue(node, record)
end

return LineNode
