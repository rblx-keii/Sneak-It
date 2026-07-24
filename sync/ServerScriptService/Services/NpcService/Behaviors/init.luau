local Behaviors = {}

local registry: { [string]: any } = {}

for _, module in script:GetChildren() do
	if not module:IsA("ModuleScript") then continue end

	local ok, behavior = pcall(require, module)
	if not ok then
		warn(`[NpcService Behaviors] Failed to require {module.Name}: {behavior}`)
		continue
	end

	registry[module.Name] = behavior
end

function Behaviors.Get(behaviorType: string): any
	return registry[behaviorType]
end

return Behaviors
