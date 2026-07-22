--!strict

local function observeClass<T>(
	className: string,
	callback: (T) -> (() -> ())?,
	root: Instance?
): () -> ()

	root = root or game

	local cleaners: { [Instance]: () -> () } = {}

	local function cleanupInstance(inst: Instance)
		local clean = cleaners[inst]
		if clean then
			cleaners[inst] = nil
			task.spawn(clean)
		end
	end

	local function handleInstance(inst: Instance)
		if not inst:IsA(className) then
			return
		end

		local ok, cleanup = xpcall(function()
			return callback(inst :: any)
		end, debug.traceback)

		if not ok then
			warn(cleanup)
			return
		end

		if cleanup then
			assert(typeof(cleanup) == "function", "callback must return function or nil")
			cleaners[inst] = cleanup
		end
	end

	for _, inst in root:GetDescendants() do
		handleInstance(inst)
	end

	local addedConn = root.DescendantAdded:Connect(handleInstance)
	local removingConn = root.DescendantRemoving:Connect(cleanupInstance)

	return function()
		addedConn:Disconnect()
		removingConn:Disconnect()

		for inst, clean in cleaners do
			task.spawn(clean)
			cleaners[inst] = nil
		end
	end
end

return observeClass