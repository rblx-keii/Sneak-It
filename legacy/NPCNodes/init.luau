--|| Types
export type NodeHandler = {
	OnArrive: (node: BasePart, record: any, npcService: any) -> (),
}

--|| MAIN ||--
local Handlers: { [string]: NodeHandler } = {}

for _, module in script:GetChildren() do
	if not module or not module:IsA("ModuleScript") then continue end

	local ok, handler = pcall(require, module)
	if not ok then
		warn(`[NPCNodes] Failed to require {module.Name}: {handler}`)
		continue
	end

	Handlers[module.Name:gsub(" ", ""):lower()] = handler :: NodeHandler
end

local NPCNodes = {}

-- Returns the handler for a normalized node-type key (e.g. "linenode"), falling
-- back to the Basic ("node") handler for unrecognized/unimplemented types so an
-- unknown node degrades to walk-through rather than stalling the NPC.
function NPCNodes.GetHandler(nodeType: string): NodeHandler?
	return Handlers[nodeType] or Handlers["node"]
end

function NPCNodes.IsKnownType(nodeType: string): boolean
	return Handlers[nodeType] ~= nil
end

return NPCNodes
