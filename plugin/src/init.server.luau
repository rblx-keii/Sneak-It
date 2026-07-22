local ServerStorage = game:GetService("ServerStorage")
local StarterGui = game:GetService("StarterGui")

local Serializer = require(script.Serializer)
local JsonPretty = require(script.JsonPretty)
local Selection = require(script.Selection)
local ListView = require(script.ListView)
local SyncClient = require(script.SyncClient)
local Theme = require(script.Theme)

local PLUGIN_FOLDER_NAME = "Mapify"
local INTERVAL_OPTIONS = { 2, 5, 10, 30, 60 }
local DEFAULT_INTERVAL = 5
local STATUS_TICK_SECONDS = 20

-- ServerStorage export -------------------------------------------------------

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		if existing:IsA("Folder") then
			return existing
		end
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Picks a Luau long-bracket level ("[[", "[=[", "[==[", ...) that cannot be
-- prematurely closed by a "]]", "]=]", etc. sequence already present in text
-- (e.g. from GUI text/attribute content), mirroring how Lua itself avoids
-- ambiguity in nested long strings/comments.
local function wrapInComment(text: string): string
	local maxLevel = -1
	for closer in text:gmatch("%]=*%]") do
		maxLevel = math.max(maxLevel, #closer - 2)
	end
	local eq = string.rep("=", maxLevel + 1)
	return `--[{eq}[\n{text}\n]{eq}]`
end

local function dumpToServerStorage(names: { string })
	local pluginFolder = getOrCreateFolder(ServerStorage, PLUGIN_FOLDER_NAME)
	local exportsFolder = getOrCreateFolder(pluginFolder, "Exports")

	local count = 0
	for _, name in names do
		local child = StarterGui:FindFirstChild(name)
		if not child or not child.Archivable then
			continue
		end

		local tree = Serializer.buildTree(child, true)
		local json = JsonPretty.encode(tree)
		local source = wrapInComment(json) .. "\nreturn nil\n"

		local existing = exportsFolder:FindFirstChild(child.Name)
		if existing then
			existing:Destroy()
		end

		local moduleScript = Instance.new("ModuleScript")
		moduleScript.Name = child.Name
		moduleScript.Source = source
		moduleScript.Parent = exportsFolder

		count += 1
	end

	print(`[Mapify] Exported {count} StarterGui instance(s) to ServerStorage.{PLUGIN_FOLDER_NAME}.Exports`)
end

-- Widget shell ---------------------------------------------------------------

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	false, -- initEnabled
	false, -- overrideEnabledRestore
	360, 540, -- floatXSize, floatYSize
	300, 420 -- minWidth, minHeight
)

local widget = plugin:CreateDockWidgetPluginGuiAsync("MapifyWidget", widgetInfo)
widget.Title = "Mapify"
widget.Name = "MapifyWidget"

local root = Instance.new("Frame")
root.Name = "Root"
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = Theme.Color.Bg
root.BorderSizePixel = 0
root.Parent = widget

local rootPadding = Instance.new("UIPadding")
rootPadding.PaddingTop = UDim.new(0, 10)
rootPadding.PaddingBottom = UDim.new(0, 10)
rootPadding.PaddingLeft = UDim.new(0, 10)
rootPadding.PaddingRight = UDim.new(0, 10)
rootPadding.Parent = root

local rootLayout = Instance.new("UIListLayout")
rootLayout.SortOrder = Enum.SortOrder.LayoutOrder
rootLayout.Padding = UDim.new(0, 8)
rootLayout.Parent = root

-- Small UI helpers -----------------------------------------------------------

-- A quiet, borderless "ghost" button — used for secondary actions that
-- shouldn't compete with the one primary call-to-action.
local function makeGhostButton(text: string, layoutOrder: number, parent: Instance): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, 0, 1, 0)
	button.AutomaticSize = Enum.AutomaticSize.X
	button.BackgroundColor3 = Theme.Color.Input
	button.AutoButtonColor = false
	button.Font = Theme.Font.Medium
	button.TextSize = 13
	button.TextColor3 = Theme.Color.Text
	button.Text = text
	button.LayoutOrder = layoutOrder
	button.Parent = parent

	Theme.Round(button, Theme.Radius.Pill)
	Theme.Hover(button, Theme.Color.Input, Theme.Color.InputHover)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = button

	return button
end

-- Header: icon + wordmark -----------------------------------------------

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 24)
header.BackgroundTransparency = 1
header.LayoutOrder = 1
header.Parent = root

local headerLayout = Instance.new("UIListLayout")
headerLayout.FillDirection = Enum.FillDirection.Horizontal
headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
headerLayout.Padding = UDim.new(0, 8)
headerLayout.Parent = header

local icon = Instance.new("ImageLabel")
icon.Name = "Icon"
icon.Size = UDim2.new(0, 22, 0, 22)
icon.BackgroundTransparency = 1
icon.Image = "rbxassetid://118972215473059"
icon.LayoutOrder = 1
icon.Parent = header

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -30, 1, 0)
title.BackgroundTransparency = 1
title.Font = Theme.Font.Title
title.TextSize = 18
title.TextColor3 = Theme.Color.Text
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Mapify"
title.LayoutOrder = 2
title.Parent = header

-- Sync card: target + status, the Argon-style pairing --------------------

local syncCard = Instance.new("Frame")
syncCard.Name = "SyncCard"
syncCard.Size = UDim2.new(1, 0, 0, 46)
syncCard.BackgroundColor3 = Theme.Color.Card
syncCard.LayoutOrder = 2
syncCard.Parent = root

Theme.Round(syncCard, Theme.Radius.Card)
Theme.Stroke(syncCard)

local syncCardPadding = Instance.new("UIPadding")
syncCardPadding.PaddingLeft = UDim.new(0, 10)
syncCardPadding.PaddingRight = UDim.new(0, 10)
syncCardPadding.PaddingTop = UDim.new(0, 6)
syncCardPadding.PaddingBottom = UDim.new(0, 6)
syncCardPadding.Parent = syncCard

local targetLabel = Instance.new("TextLabel")
targetLabel.Name = "Target"
targetLabel.Size = UDim2.new(0.6, 0, 0, 18)
targetLabel.Position = UDim2.new(0, 0, 0, 0)
targetLabel.BackgroundTransparency = 1
targetLabel.Font = Theme.Font.Bold
targetLabel.TextSize = 14
targetLabel.TextColor3 = Theme.Color.Text
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Text = "Mapify"
targetLabel.Parent = syncCard

local hostLabel = Instance.new("TextLabel")
hostLabel.Name = "Host"
hostLabel.Size = UDim2.new(0.6, 0, 0, 16)
hostLabel.Position = UDim2.new(0, 0, 0, 18)
hostLabel.BackgroundTransparency = 1
hostLabel.Font = Theme.Font.Regular
hostLabel.TextSize = 12
hostLabel.TextColor3 = Theme.Color.TextDim
hostLabel.TextXAlignment = Enum.TextXAlignment.Left
hostLabel.Text = `127.0.0.1:{SyncClient.GetPort()}`
hostLabel.Parent = syncCard

local statusLine1 = Instance.new("TextLabel")
statusLine1.Name = "StatusLine1"
statusLine1.Size = UDim2.new(0.4, 0, 0, 18)
statusLine1.Position = UDim2.new(0.6, 0, 0, 0)
statusLine1.BackgroundTransparency = 1
statusLine1.Font = Theme.Font.Medium
statusLine1.TextSize = 13
statusLine1.TextColor3 = Theme.Color.TextDim
statusLine1.TextXAlignment = Enum.TextXAlignment.Right
statusLine1.Text = "● Disconnected"
statusLine1.Parent = syncCard

local statusLine2 = Instance.new("TextLabel")
statusLine2.Name = "StatusLine2"
statusLine2.Size = UDim2.new(0.4, 0, 0, 16)
statusLine2.Position = UDim2.new(0.6, 0, 0, 18)
statusLine2.BackgroundTransparency = 1
statusLine2.FontFace = Theme.Font.Italic
statusLine2.TextSize = 12
statusLine2.TextColor3 = Theme.Color.TextFaint
statusLine2.TextXAlignment = Enum.TextXAlignment.Right
statusLine2.Text = "server not running"
statusLine2.Parent = syncCard

-- Search box -------------------------------------------------------------

local searchBox = Instance.new("TextBox")
searchBox.Name = "Search"
searchBox.Size = UDim2.new(1, 0, 0, 30)
searchBox.BackgroundColor3 = Theme.Color.Input
searchBox.ClearTextOnFocus = false
searchBox.Font = Theme.Font.Regular
searchBox.TextSize = 14
searchBox.TextColor3 = Theme.Color.Text
searchBox.PlaceholderText = "Search StarterGui..."
searchBox.PlaceholderColor3 = Theme.Color.TextFaint
searchBox.Text = ""
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.LayoutOrder = 3
searchBox.Parent = root

Theme.Round(searchBox, Theme.Radius.Input)
Theme.Stroke(searchBox)

local searchPadding = Instance.new("UIPadding")
searchPadding.PaddingLeft = UDim.new(0, 10)
searchPadding.PaddingRight = UDim.new(0, 10)
searchPadding.Parent = searchBox

-- Utility row: selection count + Select/Deselect All -----------------------

local utilityRow = Instance.new("Frame")
utilityRow.Name = "UtilityRow"
utilityRow.Size = UDim2.new(1, 0, 0, 18)
utilityRow.BackgroundTransparency = 1
utilityRow.LayoutOrder = 4
utilityRow.Parent = root

local countLabel = Instance.new("TextLabel")
countLabel.Name = "Count"
countLabel.Size = UDim2.new(0.5, 0, 1, 0)
countLabel.BackgroundTransparency = 1
countLabel.Font = Theme.Font.Regular
countLabel.TextSize = 12
countLabel.TextColor3 = Theme.Color.TextFaint
countLabel.TextXAlignment = Enum.TextXAlignment.Left
countLabel.Text = "0 selected"
countLabel.Parent = utilityRow

local selectAllButton = Instance.new("TextButton")
selectAllButton.Name = "SelectAll"
selectAllButton.Size = UDim2.new(0.5, 0, 1, 0)
selectAllButton.Position = UDim2.new(0.5, 0, 0, 0)
selectAllButton.BackgroundTransparency = 1
selectAllButton.AutoButtonColor = false
selectAllButton.Font = Theme.Font.Medium
selectAllButton.TextSize = 12
selectAllButton.TextColor3 = Theme.Color.Accent
selectAllButton.TextXAlignment = Enum.TextXAlignment.Right
selectAllButton.Text = "Select All"
selectAllButton.Parent = utilityRow

Theme.Hover(selectAllButton, Theme.Color.Accent, Theme.Color.AccentLight)

-- Checkbox list -------------------------------------------------------------

local listContainer = Instance.new("ScrollingFrame")
listContainer.Name = "List"
listContainer.Size = UDim2.new(1, 0, 0, 150)
listContainer.BackgroundColor3 = Theme.Color.Card
listContainer.BorderSizePixel = 0
listContainer.ScrollBarThickness = 6
listContainer.ScrollBarImageColor3 = Theme.Color.Accent
listContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
listContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
listContainer.LayoutOrder = 5
listContainer.Parent = root

Theme.Round(listContainer, Theme.Radius.Card)
Theme.Stroke(listContainer)

local listPadding = Instance.new("UIPadding")
listPadding.PaddingTop = UDim.new(0, 4)
listPadding.PaddingBottom = UDim.new(0, 4)
listPadding.PaddingLeft = UDim.new(0, 4)
listPadding.PaddingRight = UDim.new(0, 4)
listPadding.Parent = listContainer

local listFlex = Instance.new("UIFlexItem")
listFlex.FlexMode = Enum.UIFlexMode.Fill
listFlex.Parent = listContainer

local listView = ListView.new(listContainer)

local function updateSelectionLabels()
	local visible = listView:GetVisibleNames()
	local selected = listView:GetSelectedNames()
	countLabel.Text = `{#selected} selected`
	selectAllButton.Text = if Selection.IsAllSelected(visible) then "Deselect All" else "Select All"
end

listView:SetOnSelectionChanged(updateSelectionLabels)
updateSelectionLabels()

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	listView:SetFilter(searchBox.Text)
	updateSelectionLabels()
end)

selectAllButton.MouseButton1Click:Connect(function()
	local visible = listView:GetVisibleNames()
	if Selection.IsAllSelected(visible) then
		listView:DeselectAll()
	else
		listView:SelectAll()
	end
end)

-- Sync interval: segmented control -----------------------------------------

local intervalTrack = Instance.new("Frame")
intervalTrack.Name = "IntervalTrack"
intervalTrack.Size = UDim2.new(1, 0, 0, 30)
intervalTrack.BackgroundColor3 = Theme.Color.Input
intervalTrack.LayoutOrder = 6
intervalTrack.Parent = root

Theme.Round(intervalTrack, Theme.Radius.Input)
Theme.Stroke(intervalTrack)

local intervalPadding = Instance.new("UIPadding")
intervalPadding.PaddingTop = UDim.new(0, 3)
intervalPadding.PaddingBottom = UDim.new(0, 3)
intervalPadding.PaddingLeft = UDim.new(0, 3)
intervalPadding.PaddingRight = UDim.new(0, 3)
intervalPadding.Parent = intervalTrack

local intervalLayout = Instance.new("UIListLayout")
intervalLayout.FillDirection = Enum.FillDirection.Horizontal
intervalLayout.SortOrder = Enum.SortOrder.LayoutOrder
intervalLayout.Padding = UDim.new(0, 3)
intervalLayout.Parent = intervalTrack

local function loadInterval(): number
	local ok, value = pcall(function()
		return plugin:GetSetting("MapifySyncInterval")
	end)
	if ok and typeof(value) == "number" then
		for _, option in INTERVAL_OPTIONS do
			if option == value then
				return value
			end
		end
	end
	return DEFAULT_INTERVAL
end

local currentInterval = loadInterval()
local intervalButtons: { [number]: TextButton } = {}

local function updateIntervalButtonStyles()
	for value, button in intervalButtons do
		local selected = value == currentInterval
		button.BackgroundColor3 = if selected then Theme.Color.Accent else Theme.Color.Input
		button.TextColor3 = if selected then Theme.Color.Text else Theme.Color.TextDim
	end
end

local syncEnabled = false
local syncButton: TextButton

local function restartAutoSyncIfEnabled()
	if syncEnabled then
		SyncClient.StartAutoSync(currentInterval, function()
			return listView:GetSelectedNames()
		end)
	end
end

for i, option in INTERVAL_OPTIONS do
	local button = Instance.new("TextButton")
	button.Name = `Interval{option}`
	button.Size = UDim2.new(1 / #INTERVAL_OPTIONS, -2, 1, 0)
	button.BackgroundColor3 = Theme.Color.Input
	button.AutoButtonColor = false
	button.Font = Theme.Font.Medium
	button.TextSize = 12
	button.TextColor3 = Theme.Color.TextDim
	button.Text = `{option}s`
	button.LayoutOrder = i
	button.Parent = intervalTrack

	Theme.Round(button, Theme.Radius.Pill)

	intervalButtons[option] = button

	button.MouseButton1Click:Connect(function()
		currentInterval = option
		pcall(function()
			plugin:SetSetting("MapifySyncInterval", option)
		end)
		updateIntervalButtonStyles()
		restartAutoSyncIfEnabled()
	end)
end
updateIntervalButtonStyles()

-- Status rendering ---------------------------------------------------------

local lastStatus: SyncClient.Status = "Disconnected"
local lastDetail: string? = nil

local function formatRelativeTime(epochSeconds: number): string
	local elapsed = os.time() - epochSeconds
	if elapsed < 60 then
		return "just now"
	elseif elapsed < 3600 then
		return `{math.floor(elapsed / 60)}m ago`
	elseif elapsed < 86400 then
		return `{math.floor(elapsed / 3600)}h ago`
	else
		return `{math.floor(elapsed / 86400)}d ago`
	end
end

local function renderStatus()
	local status = lastStatus
	local detail = lastDetail
	local color = Theme.Color.TextDim
	local line1 = `● {status}`
	local line2 = ""

	if status == "Disconnected" then
		color = Theme.Color.Error
		line1 = "● Disconnected"
		line2 = "server not running"
	elseif status == "Connected" then
		color = Theme.Color.TextDim
		line1 = "● Connected"
	elseif status == "Pushing" then
		color = Theme.Color.Accent
		line1 = "● Pushing..."
	elseif status == "Synced" then
		color = Theme.Color.TextDim
		line1 = "● Synced"
		local epoch = detail and tonumber(detail)
		line2 = if epoch then formatRelativeTime(epoch) else ""
	elseif status == "Error" then
		color = Theme.Color.Error
		line1 = "● Error"
		line2 = detail or "unknown"
	end

	statusLine1.TextColor3 = color
	statusLine1.Text = line1
	statusLine2.Text = line2
end

SyncClient.SetStatusCallback(function(status, detail)
	lastStatus = status
	lastDetail = detail
	renderStatus()
end)

SyncClient.StartPingLoop()

-- Keeps "Synced Xm ago" counting up between pushes, not just refreshing on
-- the next SyncClient event.
task.spawn(function()
	while true do
		task.wait(STATUS_TICK_SECONDS)
		if lastStatus == "Synced" then
			renderStatus()
		end
	end
end)

-- Bottom row: secondary actions + one primary call-to-action ---------------

local actionRow = Instance.new("Frame")
actionRow.Name = "Actions"
actionRow.Size = UDim2.new(1, 0, 0, 32)
actionRow.BackgroundTransparency = 1
actionRow.LayoutOrder = 7
actionRow.Parent = root

local actionLayout = Instance.new("UIListLayout")
actionLayout.FillDirection = Enum.FillDirection.Horizontal
actionLayout.VerticalAlignment = Enum.VerticalAlignment.Center
actionLayout.Padding = UDim.new(0, 6)
actionLayout.Parent = actionRow

local exportButton = makeGhostButton("Export", 1, actionRow)
exportButton.MouseButton1Click:Connect(function()
	dumpToServerStorage(listView:GetSelectedNames())
end)

syncButton = makeGhostButton("Sync: Off", 2, actionRow)

local function setSyncEnabled(enabled: boolean)
	syncEnabled = enabled
	if enabled then
		restartAutoSyncIfEnabled()
		syncButton.Text = "Sync: On"
		syncButton.BackgroundColor3 = Theme.Color.Accent
	else
		SyncClient.StopAutoSync()
		syncButton.Text = "Sync: Off"
		syncButton.BackgroundColor3 = Theme.Color.Input
	end
end

syncButton.MouseButton1Click:Connect(function()
	setSyncEnabled(not syncEnabled)
end)

local pushButton = Instance.new("TextButton")
pushButton.Name = "Push"
pushButton.Size = UDim2.new(.915, 0, .875, 0)
pushButton.BackgroundColor3 = Theme.Color.Accent
pushButton.AutoButtonColor = false
pushButton.Text = ""
pushButton.LayoutOrder = 3
pushButton.Parent = actionRow

local pushFlex = Instance.new("UIFlexItem")
pushFlex.FlexMode = Enum.UIFlexMode.Fill
pushFlex.Parent = pushButton

Theme.Round(pushButton, Theme.Radius.Pill)
Theme.Gradient(pushButton, Theme.Color.AccentLight, Theme.Color.AccentDark)
Theme.Hover(pushButton, Theme.Color.Accent, Theme.Color.AccentLight)

local pushLabel = Instance.new("TextLabel")
pushLabel.Name = "Label"
pushLabel.Size = UDim2.fromScale(1, 1)
pushLabel.BackgroundTransparency = 1
pushLabel.Font = Theme.Font.Bold
pushLabel.TextSize = 14
pushLabel.TextColor3 = Theme.Color.OnAccent
pushLabel.Text = "Push to Local PC"
pushLabel.Parent = pushButton

local pushLabelPadding = Instance.new("UIPadding")
pushLabelPadding.PaddingLeft = UDim.new(0.08, 0)
pushLabelPadding.PaddingRight = UDim.new(0.08, 0)
pushLabelPadding.Parent = pushLabel

pushButton.MouseButton1Click:Connect(function()
	SyncClient.PushNow(listView:GetSelectedNames())
end)

-- Toolbar ------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("Mapify")
local toggleButton = toolbar:CreateButton(
	"Mapify",
	"Open the Mapify panel",
	"rbxassetid://118972215473059"
)
toggleButton.ClickableWhenViewportHidden = true

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)
