local Setups = {}

for _, module in script:GetChildren() do
	if not module or not module:IsA("ModuleScript") then continue end

	local ok, _setup = pcall(require, module)
	if not ok then
		warn(`[MapInteractibles] Failed to require {module.Name}: {_setup}`)
		continue
	end

	Setups[module.Name:gsub(" ", ""):lower()] = _setup
end

return function(item: Instance)
	if not Setups[item.Name:gsub(" ", ""):lower()] then
		warn(`[MapInteractibles] No setup for {item.Name}`)
		return
	end

	return Setups[item.Name:gsub(" ", ""):lower()].new(item)
end