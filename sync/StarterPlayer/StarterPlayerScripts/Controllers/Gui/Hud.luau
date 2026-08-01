--|| References
local GuiController = require(script.Parent.Parent.GuiController)
local RoundController = require(script.Parent.Parent.RoundController)
local DataController = require(script.Parent.Parent.DataController)
local GateController = require(script.Parent.Parent.GateController)

local Hud = GuiController.Guis.Hud

local timerContent = Hud.Timer.Content
local phaseLabel = timerContent.Phase :: TextLabel
local timerLabel = timerContent.Timer :: TextLabel

local playButton = Hud.Play :: ImageButton
local sidebar = Hud.Sidebar :: Frame

local tokensAmountLabel = sidebar.Tokens.Main.Content.Amount :: TextLabel

local statusFrame = Hud.Status :: Frame
local statusLabel = statusFrame.Label :: TextLabel

local subMenu = sidebar.Menu.SubMenu
local shopButton = subMenu.Shop.Content.Button :: ImageButton
local bagButton = subMenu.Bag.Content.Button :: ImageButton
local perksButton = subMenu.Perks.Content.Button :: ImageButton
local itemsButton = subMenu.Items.Content.Button :: ImageButton
local questsButton = sidebar.Menu.Quests.Button :: ImageButton

--|| Variables
local _connections = {}

--|| Constants
local PHASE_TEXT: { [RoundController.RoundState]: string } = {
	Waiting = "Waiting for Players",
	Intermission = "Starting Soon",
	MapLoading = "Loading Map",
	Starting = "Get Ready!",
	InProgress = "Round Active!",
	Ended = "Round Over",
}

local GATE_STAGE_TEXT: { [GateController.GateStage]: string } = {
	Arrived = "Airplane has arrived — boarding in %ds",
	Boarding = "Boarding now — closes in %ds",
	Departing = "Gate closed — airplane departing (%ds)",
	Waiting = "Awaiting next arrival (%ds)",
}

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, RoundController.OnStateChanged:Connect(Local.UpdatePhase))
	table.insert(_connections, RoundController.OnTimeLeftChanged:Connect(Local.UpdateTimer))
	table.insert(_connections, RoundController.OnPlayingChanged:Connect(Local.UpdateVisibility))

	table.insert(_connections, DataController.OnDataChanged:Connect(function(_action, data)
		Local.UpdateTokens(data)
	end))

	table.insert(_connections, playButton.Activated:Connect(RoundController.RequestJoin))

	table.insert(_connections, shopButton.Activated:Connect(function()
		GuiController.SwitchActiveGui("Shop")
	end))
	table.insert(_connections, bagButton.Activated:Connect(function()
		GuiController.SwitchActiveGui("Inventory")
	end))
	table.insert(_connections, perksButton.Activated:Connect(function()
		GuiController.SwitchActiveGui("Perks")
	end))
	table.insert(_connections, itemsButton.Activated:Connect(function()
		GuiController.SwitchActiveGui("Items")
	end))
	table.insert(_connections, questsButton.Activated:Connect(function()
		GuiController.SwitchActiveGui("Quest")
	end))

	table.insert(_connections, GateController.OnStageChanged:Connect(Local.UpdateStatus))
	table.insert(_connections, GateController.OnTimeLeftChanged:Connect(function(_timeLeft)
		Local.UpdateStatus(GateController.GetStage())
	end))

	Local.UpdatePhase(RoundController.GetState())
	Local.UpdateTimer(RoundController.GetTimeRemaining())
	Local.UpdateStatus(GateController.GetStage())
end

function Shared.Start()
	task.spawn(function()
		Local.UpdateTokens(DataController.GetData())
	end)
end

-- [[ Private Functions ]] --
function Local.FormatTime(seconds: number): string
	seconds = math.max(math.floor(seconds), 0)
	local minutes = seconds // 60
	local secs = seconds % 60
	return string.format("%02d:%02d Left", minutes, secs)
end

function Local.FormatNumber(amount: number): string
	local digits = tostring(math.floor(amount))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (grouped:gsub("^,", ""))
end

function Local.UpdateVisibility()
	local isPlaying = RoundController.IsPlaying()
	local state = RoundController.GetState()

	Hud.Enabled = state ~= "Ended"

	sidebar.Visible = not isPlaying
	playButton.Visible = not isPlaying and state == "InProgress"

	-- Sidebar (and its Shop/Bag/Perks/Items/Quests buttons) is hidden while playing, so close
	-- whichever submenu was left open rather than stranding it open behind a hidden sidebar.
	if isPlaying then
		GuiController.RestoreGuis()
	end
end

function Local.UpdatePhase(state: RoundController.RoundState)
	phaseLabel.Text = PHASE_TEXT[state] or state
	Local.UpdateVisibility()
end

function Local.UpdateTimer(timeLeft: number)
	local state = RoundController.GetState()
	if state == "Intermission" or state == "Starting" or state == "InProgress" then
		timerLabel.Text = Local.FormatTime(timeLeft)
	else
		timerLabel.Text = "--:--"
	end
end

function Local.UpdateTokens(data: DataController.PlayerData)
	tokensAmountLabel.Text = Local.FormatNumber(data.stats.coins)
end

function Local.UpdateStatus(stage: GateController.GateStage?)
	statusFrame.Visible = stage ~= nil
	if not stage then return end

	local template = GATE_STAGE_TEXT[stage]
	statusLabel.Text = if template then string.format(template, GateController.GetTimeLeft()) else stage
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)
end

return Shared
