local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local DEPTH = 1

return function()
	local isServer = RunService:IsServer()
	local directory = isServer and
		ServerScriptService.Services or
		Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controllers")

	local loaderStart = os.clock()

	local function elapsed(): string
		return string.format("%.3fs", os.clock() - loaderStart)
	end

	local function log(...)
		if script:GetAttribute("Debug") == true then
			warn(...)
		end
	end

	local modules = {}

	local function load(module: ModuleScript)
		local success, result = pcall(require, module)
		if not success then
			log(`[Loader +{elapsed()}] Failed to load {module.Name}: {result}`)
			return
		end
		modules[module.Name] = result
	end

	local function scan(parent: Instance, currentDepth: number)
		if currentDepth > DEPTH then return end
		for _, child in parent:GetChildren() do
			if child:IsA("ModuleScript") then
				load(child)
			elseif child:IsA("Folder") then
				scan(child, currentDepth + 1)
			end
		end
	end

	scan(directory, 0)

	local moduleArray = {}
	for name, tbl in modules do
		table.insert(moduleArray, {
			Name = name,
			Instance = tbl,
			Priority = (typeof(tbl) == "table" and tbl.Priority) or 10
		})
	end

	table.sort(moduleArray, function(a, b)
		return a.Priority < b.Priority
	end)

	-- [[ CLIENT WAIT PHASE ]] --
	if not isServer then
		if script:GetAttribute("ServerLoaded") ~= true then
			log(`[Loader +{elapsed()}] Waiting for ServerLoaded...`)
			script:GetAttributeChangedSignal("ServerLoaded"):Wait()
			log(`[Loader +{elapsed()}] ServerLoaded received`)
		end
	end

	-- [[ INIT PHASE ]] --
	local currentModule: string? = nil
	local watchdog = task.spawn(function()
		while true do
			task.wait(1)
			if currentModule then
				log(`[Loader +{elapsed()}] ⏳ Still waiting on Init: {currentModule}`)
			end
		end
	end)

	if isServer then
		for _, moduleData in moduleArray do
			if typeof(moduleData.Instance) == "table" and moduleData.Instance.Init then
				currentModule = moduleData.Name
				log(`[Loader +{elapsed()}] Init: {moduleData.Name}`)
				local initStart = os.clock()
				local ok, err = pcall(moduleData.Instance.Init)
				currentModule = nil
				if not ok then
					log(`[Loader +{elapsed()}] ❌ Init failed {moduleData.Name}: {err}`)
				else
					log(`[Loader +{elapsed()}] ✅ {moduleData.Name} ({string.format("%.3fs", os.clock() - initStart)})`)
				end
			end
		end
	else
		local initCount = 0
		local initDone = 0

		for _, moduleData in moduleArray do
			if typeof(moduleData.Instance) == "table" and moduleData.Instance.Init then
				initCount += 1
				currentModule = moduleData.Name
				log(`[Loader +{elapsed()}] Init: {moduleData.Name}`)
				local initStart = os.clock()
				task.spawn(moduleData.Instance.Init)
				initDone += 1
			end
		end

		while initDone < initCount do
			task.wait()
		end
	end

	task.cancel(watchdog)
	currentModule = nil

	-- [[ SERVER SIGNAL PHASE ]] --
	if isServer then
		script:SetAttribute("ServerLoaded", true)
		log(`[Loader +{elapsed()}] ServerLoaded set`)
	else
		local Network = require(ReplicatedStorage.Modules.Network)
		Network:SignalReady()
		log(`[Loader +{elapsed()}] SignalReady sent`)
	end

	-- [[ START PHASE ]] --
	for _, moduleData in moduleArray do
		if typeof(moduleData.Instance) == "table" and moduleData.Instance.Start then
			task.spawn(moduleData.Instance.Start)
		end
	end

	log(`[Loader +{elapsed()}] ✅ All phases complete`)
end