--|| Services
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const Players = game:GetService("Players")

--|| References
local ProfileStore = require(script.Parent.Parent.Packages.ProfileStore)
local PlayerDataTemplate = require(ReplicatedStorage.Modules.PlayerDataTemplate)
local UpdateData = require(ReplicatedStorage.Modules.Functions.UpdateData)

local Network = require(ReplicatedStorage.Modules.Network)

local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)
local UtilsLibrary = require(ReplicatedStorage.Modules.Utils.UtilsLibrary)

--|| Types
export type UpdateAction = UpdateData.UpdateAction
export type PlayerData = PlayerDataTemplate.PlayerData
export type Profile = ProfileStore.Profile<PlayerDataTemplate.PlayerData>

--|| Variables
local _profiles: { [Player]: Profile } = {}
local _cleanupTasks: { (Player) -> () } = {}

--|| Constants
local IS_STUDIO = RunService:IsStudio()
local IS_MOCK = false

local DATASTORE_NAME = IS_STUDIO and "TESTING_v1.0" or "PRODUCTION"

local PlayerStore = (IS_MOCK and IS_STUDIO)
	and ProfileStore.New(DATASTORE_NAME, PlayerDataTemplate.PLAYER_DATA_TEMPLATE).Mock
	or ProfileStore.New(DATASTORE_NAME, PlayerDataTemplate.PLAYER_DATA_TEMPLATE)

--|| MAIN ||--
local Local = {}
local Shared = {}

Shared.Priority = -1

-- [[ Signals ]] --
Shared.OnDataLoaded = ModuleUtils.signal.new()
Shared.OnDataChanged = ModuleUtils.signal.new()
Shared.OnDataReleased = ModuleUtils.signal.new()

-- [[ Startup ]] --
function Shared.Init()
	Network:BindEvent("PlayerData", "Sync", function(player: Player)
		local profile = _profiles[player]
		if profile then
			Network:FireClient("PlayerData", player, "Sync", profile.Data)
		end
	end)

	local CLIENT_ALLOWED = {
		"UpdateSettings",
		"UpdateMobileLayout",
		"SetLoadout",
	}

	Network:BindEvent("PlayerData", "Update", function(player: Player, payload: any)
		if type(payload) ~= "table" or not payload.type then return end
		if not table.find(CLIENT_ALLOWED, payload.type) then return end

		Shared.UpdateData(player, payload)
	end)

	Players.PlayerAdded:Connect(Local.OnPlayerAdded)
	Players.PlayerRemoving:Connect(Local.OnPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(Local.OnPlayerAdded, player)
	end
end

function Shared.Start() end

-- [[ Private Functions ]] --
function Local.OnPlayerAdded(player: Player)
	local key = `PLAYER_{player.UserId}`
	local profile = PlayerStore:StartSessionAsync(key, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	}) :: Profile

	if profile == nil then
		player:Kick("Failed to load your data. Please rejoin.")
		return
	end

	profile:Reconcile()
	profile:AddUserId(player.UserId)

	profile.OnSessionEnd:Connect(function()
		_profiles[player] = nil
		player:Kick("Your data session has ended. Please rejoin.")
	end)

	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	if IS_STUDIO then
		profile.Data = UtilsLibrary.tableUtils.DeepCopy(
			PlayerDataTemplate.PLAYER_DATA_TEMPLATE
		)
		profile.Data.settings.music = false
		profile.Data.settings.sfx = false
		profile.Data.stats.coins = 1_000_000_000
		profile.Data.profile.smugglerWins = 100
		profile.Data.profile.tsaWins = 100
	end

	_profiles[player] = profile

	Local.CreateLeaderstats(player, profile.Data)

	Network:FireClient("PlayerData", player, "Sync", profile.Data)
	Shared.OnDataLoaded:Fire(player, profile.Data)
end

function Local.OnPlayerRemoving(player: Player)
	local profile = _profiles[player]
	if not profile then return end

	for _, task_ in _cleanupTasks do
		local ok, err = pcall(task_, player)
		if not ok then
			warn(`[DataService] Cleanup task failed for {player.Name}: {err}`)
		end
	end

	Shared.OnDataReleased:Fire(player)
	_profiles[player] = nil
	profile:EndSession()
end

function Local.CreateLeaderstats(player: Player, data: PlayerData)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Value = data.profile.totalWins
	wins.Parent = leaderstats

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = data.stats.coins
	coins.Parent = leaderstats

	local arrests = Instance.new("IntValue")
	arrests.Name = "Arrests"
	arrests.Value = data.profile.totalArrests
	arrests.Parent = leaderstats
end

function Local.SyncLeaderstats(player: Player, data: PlayerData)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return end

	local wins = leaderstats:FindFirstChild("Wins")
	if wins then wins.Value = data.profile.totalWins end

	local coins = leaderstats:FindFirstChild("Coins")
	if coins then coins.Value = data.stats.coins end

	local arrests = leaderstats:FindFirstChild("Arrests")
	if arrests then arrests.Value = data.profile.totalArrests end
end

-- [[ Public Functions ]] --
function Shared.GetProfile(player: Player): Profile?
	return _profiles[player]
end

function Shared.GetData(player: Player): PlayerData?
	local profile = _profiles[player]
	return profile and profile.Data or nil
end

function Shared.IsDataLoaded(player: Player): boolean
	return _profiles[player] ~= nil
end

function Shared.UpdateData(player: Player, action: UpdateAction?)
	local profile = _profiles[player]
	if not profile then
		warn("[DataService] UpdateData called for unloaded player:", player.Name)
		return
	end

	if action then
		UpdateData(profile.Data, action)
	end

	Local.SyncLeaderstats(player, profile.Data)

	Network:FireClient("PlayerData", player, "Update", {
		action = action,
		data = action == nil and profile.Data or nil,
	})

	Shared.OnDataChanged:Fire(player, action, profile.Data)
end

function Shared.SubscribeCleanup(hook: (Player) -> ()): () -> ()
	table.insert(_cleanupTasks, hook)

	return function()
		local idx = table.find(_cleanupTasks, hook)
		if idx then
			table.remove(_cleanupTasks, idx)
		end
	end
end

return Shared