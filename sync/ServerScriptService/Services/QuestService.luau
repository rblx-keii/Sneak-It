--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local DataService = require(script.Parent.DataService)
local QuestsConfig = require(ReplicatedStorage.Modules.Configs.QuestsConfig)
local Network = require(ReplicatedStorage.Modules.Network)

--|| Types
type Category = QuestsConfig.QuestCategory

--|| Variables
local _networkConnections: { Network.Cleanup } = {}
local _dataConnections: { RBXScriptConnection } = {}

--|| Constants
local SLOT_COUNT: { [Category]: number } = { Daily = 3, Weekly = 1 }
local WEEK_SECONDS = 7 * 24 * 60 * 60

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Quests", "RequestClaim", function(player: Player, data: { category: Category?, id: string? })
		Local.HandleRequestClaim(player, data)
	end))

	table.insert(_dataConnections, DataService.OnDataLoaded:Connect(function(player: Player, playerData: DataService.PlayerData)
		Local.CheckReset(player, playerData, "Daily")
		Local.CheckReset(player, playerData, "Weekly")
	end))

	table.insert(_dataConnections, DataService.OnDataChanged:Connect(function(player: Player, action, playerData: DataService.PlayerData)
		if action and action.type == "UpdateProfile" then
			Local.OnStatUpdated(player, action.data.key, action.data.amount, playerData)
		end
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --

-- Daily rolls over at UTC midnight (same "!%Y-%m-%d" string convention as RewardService's
-- lastWinDate); Weekly rolls over every 7 days from the Unix epoch (Thursday-aligned, not
-- calendar-week-aligned — a consistent non-drifting bucket, not tied to a specific weekday).
function Local.GetResetId(category: Category): string
	if category == "Daily" then
		return os.date("!%Y-%m-%d")
	end
	return tostring(math.floor(os.time() / WEEK_SECONDS))
end

function Local.CheckReset(player: Player, playerData: DataService.PlayerData, category: Category)
	local resetId = Local.GetResetId(category)
	if playerData.quests[category].resetId == resetId then return end

	local ids = QuestsConfig.GetRandomIds(category, SLOT_COUNT[category])
	DataService.UpdateData(player, { type = "AssignQuests", data = { category = category, resetId = resetId, ids = ids } })
end

function Local.OnStatUpdated(player: Player, key: any, amount: any, playerData: DataService.PlayerData)
	if typeof(key) ~= "string" or typeof(amount) ~= "number" then return end

	for _, category in { "Daily", "Weekly" } :: { Category } do
		for _, quest in playerData.quests[category].active do
			if quest.claimed then continue end

			local entry = QuestsConfig.GetEntry(quest.id)
			if not entry or entry.objective ~= key then continue end

			local newProgress = math.min(quest.progress + amount, entry.target)
			if newProgress == quest.progress then continue end

			DataService.UpdateData(player, {
				type = "SetQuestProgress",
				data = { category = category, id = quest.id, progress = newProgress },
			})
		end
	end
end

function Local.HandleRequestClaim(player: Player, data: { category: Category?, id: string? })
	if not DataService.IsDataLoaded(player) then return end

	local category = data.category
	local id = data.id
	if category ~= "Daily" and category ~= "Weekly" then return end
	if typeof(id) ~= "string" or id == "" then return end

	local entry = QuestsConfig.GetEntry(id)
	if not entry then
		Network:FireClient("Quests", player, "ClaimResult", { success = false, reason = "Unknown quest", category = category, id = id })
		return
	end

	local playerData = DataService.GetData(player)
	if not playerData then return end

	local quest = nil
	for _, activeQuest in playerData.quests[category].active do
		if activeQuest.id == id then
			quest = activeQuest
			break
		end
	end

	if not quest then
		Network:FireClient("Quests", player, "ClaimResult", { success = false, reason = "Not active", category = category, id = id })
		return
	end

	if quest.claimed then
		Network:FireClient("Quests", player, "ClaimResult", { success = false, reason = "Already claimed", category = category, id = id })
		return
	end

	if quest.progress < entry.target then
		Network:FireClient("Quests", player, "ClaimResult", { success = false, reason = "Not complete", category = category, id = id })
		return
	end

	DataService.UpdateData(player, { type = "ClaimQuest", data = { category = category, id = id } })
	DataService.UpdateData(player, { type = "AddCoins", data = { amount = entry.reward } })

	Network:FireClient("Quests", player, "ClaimResult", { success = true, category = category, id = id, reward = entry.reward })
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	for _, conn in _dataConnections do
		conn:Disconnect()
	end
	table.clear(_dataConnections)
end

return Shared
