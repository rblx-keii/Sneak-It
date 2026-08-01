--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local QuestsConfig = require(ReplicatedStorage.Modules.Configs.QuestsConfig)
local GuiController = require(script.Parent.Parent.GuiController)
local DataController = require(script.Parent.Parent.DataController)
local UtilsLibrary = require(ReplicatedStorage.Modules.Utils.UtilsLibrary)
local TimeFormat = UtilsLibrary.formatUtils.Time

local Gui = GuiController.Guis.Quest
local container = Gui.Frame.Content.Container
local dailyFrame = container.Daily
local weeklyDetails = container.Weekly.Details
local weeklyTimerLabel = container.Footer.Timer :: TextLabel

--|| Types
type Category = QuestsConfig.QuestCategory
type ActiveQuest = { id: string, progress: number, claimed: boolean }

type Slot = {
	id: string?,
	title: TextLabel,
	description: TextLabel,
	fill: Frame,
	fractionLabel: TextLabel,
	fractionSuffix: string,
	rewardAmount: TextLabel,
	claimButton: TextButton,
	claimLabel: TextLabel,
}

--|| Variables
local _networkConnections: { Network.Cleanup } = {}
local _connections: { RBXScriptConnection } = {}
local _dailySlots: { Slot } = {}
local _weeklySlot: Slot? = nil
local _timerThread: thread? = nil

--|| Constants
local DAILY_SLOT_NAMES = { "Quest_1", "Quest_2", "Quest_3" }
local DAY_SECONDS = 24 * 60 * 60
local WEEK_SECONDS = 7 * DAY_SECONDS
local CLAIMED_LABEL_TRANSPARENCY = 0.5

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	for _, slotName in DAILY_SLOT_NAMES do
		local frame = dailyFrame:FindFirstChild(slotName) :: Frame?
		if not frame then continue end

		local content = frame.Content
		local progress = content.Progress
		local reward = frame.Content.Reward

		local slot: Slot = {
			id = nil,
			title = content.Title,
			description = content.Description,
			fill = progress.ProgressBar.Value,
			fractionLabel = progress.Label,
			fractionSuffix = " Complete",
			rewardAmount = reward.Content.Amount,
			claimButton = reward.Claim.Button,
			claimLabel = reward.Claim.Label,
		}

		table.insert(_connections, slot.claimButton.Activated:Connect(function()
			Local.RequestClaim("Daily", slot)
		end))

		table.insert(_dailySlots, slot)
	end

	do
		local content = weeklyDetails.Content
		local progress = content.Progress
		local reward = weeklyDetails.Reward

		local slot: Slot = {
			id = nil,
			title = content.Title,
			description = content.Description,
			fill = progress.ProgressBar.Bar.Value,
			fractionLabel = progress.Value,
			fractionSuffix = "",
			rewardAmount = reward.Content.Amount,
			claimButton = reward.Claim.Button,
			claimLabel = reward.Claim.Label,
		}

		table.insert(_connections, slot.claimButton.Activated:Connect(function()
			Local.RequestClaim("Weekly", slot)
		end))

		_weeklySlot = slot
	end

	table.insert(_networkConnections, Network:BindEvent("Quests", "ClaimResult", function(result: { success: boolean, reason: string? })
		if not result.success then
			warn("[Quests] Claim failed:", result.reason)
		end
	end))

	table.insert(_connections, DataController.OnDataChanged:Connect(function(_action, data: DataController.PlayerData)
		Local.ApplyData(data)
	end))

	_timerThread = task.spawn(Local.RunResetTimer)
end

function Shared.Start()
	task.spawn(function()
		Local.ApplyData(DataController.GetData())
	end)
end

-- [[ Private Functions ]] --
function Local.ApplyData(data: DataController.PlayerData)
	local dailyActive = data.quests.Daily.active
	for index, slot in _dailySlots do
		Local.RefreshSlot(slot, dailyActive[index])
	end

	if _weeklySlot then
		Local.RefreshSlot(_weeklySlot, data.quests.Weekly.active[1])
	end
end

function Local.RefreshSlot(slot: Slot, questProgress: ActiveQuest?)
	if not questProgress then
		slot.id = nil
		slot.title.Text = "No quest assigned"
		slot.description.Text = ""
		slot.fractionLabel.Text = ""
		slot.fill.Size = UDim2.new(0, 0, 1, 0)
		slot.rewardAmount.Text = ""
		slot.claimButton.Active = false
		slot.claimLabel.Text = ""
		return
	end

	local entry = QuestsConfig.GetEntry(questProgress.id)
	if not entry then return end

	slot.id = questProgress.id
	slot.title.Text = entry.displayName
	slot.description.Text = entry.description
	slot.fractionLabel.Text = `{questProgress.progress}/{entry.target}{slot.fractionSuffix}`
	slot.fill.Size = UDim2.new(math.clamp(questProgress.progress / entry.target, 0, 1), 0, 1, 0)
	slot.rewardAmount.Text = tostring(entry.reward)

	local complete = questProgress.progress >= entry.target
	slot.claimButton.Active = complete and not questProgress.claimed
	slot.claimLabel.TextTransparency = if questProgress.claimed then CLAIMED_LABEL_TRANSPARENCY else 0

	if questProgress.claimed then
		slot.claimLabel.Text = "Claimed"
	elseif complete then
		slot.claimLabel.Text = "Claim!"
	else
		slot.claimLabel.Text = "In Progress"
	end
end

function Local.RequestClaim(category: Category, slot: Slot)
	if not slot.claimButton.Active or not slot.id then return end
	Network:FireServer("Quests", "RequestClaim", { category = category, id = slot.id })
end

function Local.RunResetTimer()
	while true do
		local now = os.time()
		local nextDailyReset = (now // DAY_SECONDS + 1) * DAY_SECONDS
		local nextWeeklyReset = (now // WEEK_SECONDS + 1) * WEEK_SECONDS

		local dailyText = TimeFormat.FormatHMS(nextDailyReset - now, "h m s")
		local weeklyText = TimeFormat.FormatDHMSFull(nextWeeklyReset - now)

		weeklyTimerLabel.Text = `<font color="rgb(0,27,72)">Daily Quests refreshes in <font weight="700">{dailyText}</font> | Weekly Objective refreshes in <font weight="700">{weeklyText}</font>.</font>`
		task.wait(1)
	end
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	if _timerThread then
		task.cancel(_timerThread)
		_timerThread = nil
	end
end

return Shared
