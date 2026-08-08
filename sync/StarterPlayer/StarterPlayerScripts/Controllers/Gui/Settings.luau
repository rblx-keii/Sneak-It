--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

--|| References
local Icon = require(ReplicatedStorage.Modules.Libs.TopbarPlus)
local SettingsConfig = require(ReplicatedStorage.Modules.Configs.SettingsConfig)

local GuiController = require(script.Parent.Parent.GuiController)
local DataController = require(script.Parent.Parent.DataController)
local MobileControlsController = require(script.Parent.Parent.MobileControlsController)

local Gui = GuiController.Guis.Settings
local rootFrame = Gui.Frame
local exitButton = rootFrame.Exit :: ImageButton
local container = rootFrame.Content.Contatiner :: ScrollingFrame
local template = container.Template :: Frame

template.Visible = false

--|| Variables
local _connections: { RBXScriptConnection } = {}
local _settingsIcon: any = nil
local _mobileOnlyRows: { Frame } = {}

--|| Constants
local TRACKABLE_INPUT_TYPES = { Enum.UserInputType.Touch, Enum.UserInputType.MouseButton1 }
local TOPBAR_ICON_ID = "rbxassetid://11385220714"

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, exitButton.Activated:Connect(GuiController.RestoreGuis))

	_settingsIcon = Icon.new()
		:setImage(TOPBAR_ICON_ID)
		:setLabel("Settings")

	_settingsIcon:bindEvent("selected", function()
		GuiController.SwitchActiveGui("Settings")
	end)

	-- GuiController's activeGuiName is the single source of truth (it already handles the
	-- click-to-close-again toggle) — the icon just mirrors it, whether closed via this icon,
	-- the Exit button, or another gui taking over.
	table.insert(_connections, GuiController.onActiveGuiChanged:Connect(function(name: string?)
		if name == "Settings" then
			_settingsIcon:select()
		else
			_settingsIcon:deselect()
		end
	end))
end

function Shared.Start()
	table.insert(_connections, GuiController.OnMobileLayoutChanged:Connect(Local.UpdateMobileOnlyRows))

	task.spawn(function()
		local data = DataController.GetData()
		for _, entry in SettingsConfig do
			Local.CreateRow(entry, data)
		end
		Local.UpdateMobileOnlyRows(GuiController.IsMobileLayout)
	end)
end

-- [[ Private Functions ]] --
function Local.HandleButtonAction(id: string)
	warn(`[Settings] {id} button pressed`)
	if id == "MobileControls" then
		GuiController.RestoreGuis()
		MobileControlsController.OpenEditor()
	end
end

function Local.UpdateMobileOnlyRows(isMobile: boolean)
	for _, row in _mobileOnlyRows do
		row.Visible = isMobile
	end
end

function Local.CreateRow(entry: SettingsConfig.SettingEntry, data: DataController.PlayerData)
	local row = template:Clone()
	row.Name = entry.id
	row.Visible = true

	local content = row.Content :: Frame
	local titleLabel = content.Title :: TextLabel
	local descLabel = content.Description :: TextLabel
	local sliderFrame = content.Slider :: Frame
	local buttonFrame = content.Button :: Frame

	titleLabel.Text = entry.title
	descLabel.Text = entry.description

	if entry.kind == "Slider" then
		sliderFrame.Visible = true
		buttonFrame.Visible = false
		Local.SetupSlider(sliderFrame, entry, data.settings[entry.settingKey :: string])
	else
		sliderFrame.Visible = false
		buttonFrame.Visible = true

		local button = buttonFrame:FindFirstChild("Button") :: TextButton
		button.Text = entry.buttonText or "Edit"
		table.insert(_connections, button.Activated:Connect(function()
			Local.HandleButtonAction(entry.id)
		end))
	end

	if entry.mobileOnly then
		table.insert(_mobileOnlyRows, row)
	end

	row.Parent = container
end

-- Drag math mirrors the mobile joystick's: track a single input, clamp to the bar's bounds, apply
-- the value live while dragging and persist it only once on release.
function Local.SetupSlider(sliderFrame: Frame, entry: SettingsConfig.SettingEntry, currentValue: number)
	local bar = sliderFrame:FindFirstChild("Bar") :: Frame
	local knob = sliderFrame:FindFirstChild("Button") :: Frame
	local knobButton = knob:FindFirstChild("Button") :: TextButton
	local knobY = knob.Position.Y

	local min = entry.min or 0
	local max = entry.max or 100

	knobButton.Active = true

	local function setPercent(percent: number): number
		percent = math.clamp(percent, 0, 1)

		local barWidth = bar.AbsoluteSize.X
		local sliderWidth = sliderFrame.AbsoluteSize.X
		if barWidth > 0 and sliderWidth > 0 then
			local targetX = bar.AbsolutePosition.X - sliderFrame.AbsolutePosition.X + percent * barWidth
			knob.Position = UDim2.new(targetX / sliderWidth, 0, knobY.Scale, knobY.Offset)
		end

		knobButton.Text = `{math.floor(percent * 100 + 0.5)}%`
		return percent
	end

	setPercent((currentValue - min) / (max - min))

	local trackedInput: InputObject? = nil

	local function percentFromInput(inputPos: Vector3): number
		local barWidth = bar.AbsoluteSize.X
		if barWidth <= 0 then return 0 end
		return (inputPos.X - bar.AbsolutePosition.X) / barWidth
	end

	table.insert(_connections, knobButton.InputBegan:Connect(function(input: InputObject)
		-- Touch can re-fire InputBegan on a *different* active GuiButton (e.g. another slider's knob)
		-- when a drag already in progress elsewhere passes over it, without the finger lifting —
		-- checking UserInputState rejects those phantom re-fires so this slider can't hijack the drag.
		if trackedInput or input.UserInputState ~= Enum.UserInputState.Begin
			or not table.find(TRACKABLE_INPUT_TYPES, input.UserInputType) then
			return
		end
		trackedInput = input
		warn(`[Settings] {entry.id} slider drag started`)
		setPercent(percentFromInput(input.Position))
	end))

	table.insert(_connections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		setPercent(percentFromInput(input.Position))
	end))

	table.insert(_connections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		trackedInput = nil
		warn(`[Settings] {entry.id} slider drag stopped`)

		local percent = setPercent(percentFromInput(input.Position))
		local value = math.floor(min + percent * (max - min) + 0.5)

		DataController.RequestUpdate({
			type = "UpdateSettings",
			data = { key = entry.settingKey, value = value },
		})
	end))
end

-- [[ Public Functions ]] --
function Shared.Open()
	GuiController.SwitchActiveGui("Settings")
end

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	if _settingsIcon then
		_settingsIcon:destroy()
		_settingsIcon = nil
	end
end

return Shared
