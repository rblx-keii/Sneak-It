--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)

local RoundService = require(script.Parent.RoundService)
local MapService = require(script.Parent.MapService)
local ItemService = require(script.Parent.ItemService)

--|| Types
type SpawnPoint = {
	part: BasePart,
	items: { string }?,
	types: { string },
	currentItem: Model?,
	watchConn: RBXScriptConnection?,
	respawnThread: thread?,
}

type Candidate = {
	name: string,
	weight: number,
}

--|| Variables
local _connections: { RBXScriptConnection } = {}

local Local = {}
local Shared = {}

Local.spawnPoints = {} :: { SpawnPoint }

--|| Constants
local ITEM_SPAWNS_FOLDER_NAME = "ItemSpawns"
local DEFAULT_ITEM_TYPE = "Non-functional"
local DEFAULT_SPAWN_WEIGHT = 10
local RESPAWN_DELAY = 15

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, RoundService.OnStateChange:Connect(Local.OnRoundStateChange))

	local currentState = RoundService.GetState()
	if currentState == "Starting" or currentState == "InProgress" then
		Local.SpawnRound()
	end
end

function Shared.Start()

end

-- [[ Private Functions — Round lifecycle ]] --
function Local.OnRoundStateChange(newState: string)
	if newState == "Starting" then
		Local.SpawnRound()
	elseif newState == "Ended" or newState == "Intermission" then
		Local.DespawnAll()
	end
end

function Local.SpawnRound()
	Local.DespawnAll()

	local activeMap = MapService.GetActiveMap()
	if not activeMap then
		warn("[ItemSpawnService] No active map — cannot set up item spawns")
		return
	end

	local spawnsFolder = activeMap:FindFirstChild(ITEM_SPAWNS_FOLDER_NAME)
	if not spawnsFolder then
		warn("[ItemSpawnService] Active map has no ItemSpawns folder — no items will be spawned")
		return
	end

	for _, part in spawnsFolder:GetChildren() do
		if part:IsA("BasePart") then
			Local.RegisterSpawnPoint(part)
		end
	end
end

function Local.DespawnAll()
	for _, spawnPoint in Local.spawnPoints do
		if spawnPoint.watchConn then
			spawnPoint.watchConn:Disconnect()
			spawnPoint.watchConn = nil
		end

		if spawnPoint.respawnThread then
			task.cancel(spawnPoint.respawnThread)
			spawnPoint.respawnThread = nil
		end

		if spawnPoint.currentItem and spawnPoint.currentItem.Parent then
			spawnPoint.currentItem:Destroy()
		end
		spawnPoint.currentItem = nil
	end

	table.clear(Local.spawnPoints)
end

-- [[ Private Functions — Spawn point setup ]] --
function Local.RegisterSpawnPoint(part: BasePart)
	local itemsAttr = part:GetAttribute("Items")
	local typeAttr = part:GetAttribute("ItemsType")

	local explicitItems: { string }? = nil
	if typeof(itemsAttr) == "string" and itemsAttr ~= "" then
		explicitItems = Local.SplitList(itemsAttr)
	end

	local types: { string }
	if typeof(typeAttr) == "string" and typeAttr ~= "" then
		types = Local.SplitList(typeAttr)
	else
		types = { DEFAULT_ITEM_TYPE }
	end

	local spawnPoint: SpawnPoint = {
		part = part,
		items = explicitItems,
		types = types,
		currentItem = nil,
		watchConn = nil,
		respawnThread = nil,
	}

	table.insert(Local.spawnPoints, spawnPoint)
	Local.SpawnItemAt(spawnPoint)
end

function Local.SplitList(value: string): { string }
	local result = {}
	for entry in value:gmatch("[^,]+") do
		local trimmed = entry:match("^%s*(.-)%s*$"):gsub(" ", "")
		if trimmed ~= "" then
			table.insert(result, trimmed)
		end
	end
	return result
end

-- [[ Private Functions — Candidate selection ]] --
function Local.BuildCandidates(spawnPoint: SpawnPoint): { Candidate }
	local seen: { [string]: boolean } = {}
	local candidates: { Candidate } = {}

	local function addCandidate(name: string)
		if seen[name] then return end

		local config = ItemsConfig.GetItem(name)
		if not config then
			warn(`[ItemSpawnService] Spawn point "{spawnPoint.part:GetFullName()}" references unknown item "{name}"`)
			return
		end

		seen[name] = true
		local weight = config.properties.spawnWeight or DEFAULT_SPAWN_WEIGHT
		table.insert(candidates, { name = name, weight = weight })
	end

	if spawnPoint.items then
		for _, name in spawnPoint.items do
			addCandidate(name)
		end
	end

	for name, config in ItemsConfig.Items do
		local itemType = config.properties.itemType or DEFAULT_ITEM_TYPE
		if table.find(spawnPoint.types, itemType) then
			addCandidate(name)
		end
	end

	return candidates
end

function Local.WeightedPick(candidates: { Candidate }): string?
	local total = 0
	for _, candidate in candidates do
		total += math.max(candidate.weight, 0)
	end
	if total <= 0 then return nil end

	local roll = math.random() * total
	local cumulative = 0

	for _, candidate in candidates do
		cumulative += math.max(candidate.weight, 0)
		if roll <= cumulative then
			return candidate.name
		end
	end

	return candidates[#candidates].name
end

-- [[ Private Functions — Spawn / respawn ]] --
function Local.SpawnItemAt(spawnPoint: SpawnPoint)
	if spawnPoint.currentItem then return end

	local candidates = Local.BuildCandidates(spawnPoint)
	if #candidates == 0 then
		warn(`[ItemSpawnService] Spawn point "{spawnPoint.part:GetFullName()}" has no eligible items to spawn`)
		return
	end

	local itemName = Local.WeightedPick(candidates)
	if not itemName then return end

	local item = ItemService.SpawnItem(itemName, spawnPoint.part.CFrame)
	if not item then return end

	spawnPoint.currentItem = item

	spawnPoint.watchConn = item:GetPropertyChangedSignal("Parent"):Connect(function()
		Local.OnItemLeftSpawn(spawnPoint, item)
	end)
end

function Local.OnItemLeftSpawn(spawnPoint: SpawnPoint, item: Model)
	if spawnPoint.currentItem ~= item then return end

	spawnPoint.currentItem = nil

	if spawnPoint.watchConn then
		spawnPoint.watchConn:Disconnect()
		spawnPoint.watchConn = nil
	end

	spawnPoint.respawnThread = task.delay(RESPAWN_DELAY, function()
		spawnPoint.respawnThread = nil
		Local.SpawnItemAt(spawnPoint)
	end)
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	Local.DespawnAll()
end

return Shared
