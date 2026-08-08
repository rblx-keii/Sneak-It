--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--|| References
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: typeof(StarterGui)
local camera = workspace.CurrentCamera

--|| Constants
local BASE_WIDTH = 1920
local MIN_RATIO = 0.01

-- TouchEnabled alone would also catch tablets/iPads, which already have plenty of screen space —
-- the viewport-width floor is what actually limits this to phone-sized touch screens.
local MOBILE_MIN_VIEWPORT_X = 950

local MOBILE_LAYOUT_OVERRIDES: { {
	gui: string,
	element: string,
	position: UDim2?,
	size: UDim2?,
} } = {
	{ gui = "Hotbar", element = "Frame", position = UDim2.fromScale(0.5, 0.996), size = UDim2.fromScale(0.488, 0.127) },
	{ gui = "Cursor", element = "Frame", position = UDim2.fromScale(0.5, 0.5), size = UDim2.fromScale(0.009, 0.018) },
	{ gui = "Hud", element = "Sidebar", position = UDim2.fromScale(0.026, 0.5), size = UDim2.fromScale(0.142, 0.496) },
	{ gui = "Hud", element = "Status", position = UDim2.fromScale(0.5, 0.166), size = UDim2.fromScale(0.473, 0.064) },
	{ gui = "Hud", element = "Timer", position = UDim2.fromScale(0.5, 0.026), size = UDim2.fromScale(0.262, 0.115) },
	{ gui = "Inventory", element = "Frame", size = UDim2.new(0.676, 0, 0.559, 25) },
	{ gui = "Items", element = "Frame", size = UDim2.new(0.676, 0, 0.559, 25) },
	{ gui = "Perks", element = "Frame", size = UDim2.new(0.676, 0, 0.559, 25) },
	{ gui = "Quest", element = "Frame", size = UDim2.new(0.676, 0, 0.559, 25) },
	{ gui = "Shop", element = "Frame", size = UDim2.new(0.676, 0, 0.559, 25) },
	{ gui = "Alarm", element = "List", position = UDim2.fromScale(0.5, 0.527), size = UDim2.fromScale(0.505, 0.561) },
}

--|| Variables
local activeGuiName = nil
local frameConns = {}
local ignored = {}
local scrollbarRatios = {}
local originalLayout: { [GuiObject]: { position: UDim2, size: UDim2 } } = {}
local isMobileLayout = false

--|| MAIN ||--
local Local = {}
local Shared = {}

Shared.Priority = -1

--[[ Signals ]]--
Shared.onActiveGuiChanged = ModuleUtils.signal.new()
Shared.OnMobileLayoutChanged = ModuleUtils.signal.new()
Shared.OnTouchDeviceChanged = ModuleUtils.signal.new()

Shared.IsMobileLayout = false

-- Not viewport-gated like IsMobileLayout (which also excludes tablets by screen width) — this is
-- what decides whether we take over from Roblox's default TouchGui at all. PreferredInput is
-- Roblox's own live source of truth for this (ControlModule uses the same property to pick a
-- controller), so it reacts correctly when e.g. a tablet's keyboard/mouse disconnects mid-session.
Shared.IsTouchDevice = false

--[[ GUIS ]]--

Shared.Guis = {
	Alarm = playerGui:WaitForChild("Alarm") :: typeof(StarterGui.Alarm),
	Cursor = playerGui:WaitForChild("Cursor") :: typeof(StarterGui.Cursor),
	Hotbar = playerGui:WaitForChild("Hotbar") :: typeof(StarterGui.Hotbar),
	Hud = playerGui:WaitForChild("Hud") :: typeof(StarterGui.Hud),
	Interact = playerGui:WaitForChild("Interact") :: typeof(StarterGui.Interact),
	Inventory = playerGui:WaitForChild("Inventory") :: typeof(StarterGui.Inventory),
	Items = playerGui:WaitForChild("Items") :: typeof(StarterGui.Items),
	MobileControls = playerGui:WaitForChild("MobileControls") :: typeof(StarterGui.MobileControls),
	Perks = playerGui:WaitForChild("Perks") :: typeof(StarterGui.Perks),
	Quest = playerGui:WaitForChild("Quests") :: typeof(StarterGui.Quests),
	Settings = playerGui:WaitForChild("Settings") :: typeof(StarterGui.Settings),
	Shop = playerGui:WaitForChild("Shop") :: typeof(StarterGui.Shop)
}

--[[ Startup ]]--
function Shared.Init()
	for _, gui in Shared.Guis do
		if not gui then continue end
		for _, descendant in gui:GetDescendants() do
			if descendant:IsA("ScrollingFrame") and descendant.ScrollBarThickness > 0 then
				Local.cacheScrollbarRatio(descendant)
			end
		end

		local isStartup = gui:GetAttribute("Startup") == true
		gui.Enabled = isStartup

		if isStartup then
			table.insert(ignored, gui)
		end
	end

	camera:GetPropertyChangedSignal("ViewportSize"):Connect(Local.updateAllScrollbars)
	Local.updateAllScrollbars()

	for _, entry in MOBILE_LAYOUT_OVERRIDES do
		local gui = Shared.Guis[entry.gui]
		local element = gui and gui:FindFirstChild(entry.element)
		if element then
			originalLayout[element] = { position = element.Position, size = element.Size }
		end
	end

	camera:GetPropertyChangedSignal("ViewportSize"):Connect(Local.updateMobileLayout)
	Local.updateMobileLayout()

	UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(Local.updateTouchDevice)
	Local.updateTouchDevice()

	for _, frame in CollectionService:GetTagged("FrameButton") do
		Local.addFrameButton(frame)
	end

	CollectionService:GetInstanceAddedSignal("FrameButton"):Connect(Local.addFrameButton)

	for _, frame in CollectionService:GetTagged("ExitButton") do
		if not frame or not frame:IsDescendantOf(player) then continue end
		local button = frame:FindFirstChild("Button") :: GuiButton
		if not button and frame:IsA("GuiButton") then
			button = frame
		end

		button.Activated:Connect(function()
			task.delay(.2, function()
				Shared.RestoreGuis()
			end)
		end)
	end
end

function Shared.Start()

end

--[[ Private Functions ]]--

function Local.cacheScrollbarRatio(scrollingFrame: ScrollingFrame)
	local ratio = scrollingFrame.ScrollBarThickness / BASE_WIDTH
	scrollingFrame.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	scrollbarRatios[scrollingFrame] = math.max(ratio, MIN_RATIO)
end

function Local.updateAllScrollbars()
	local currentWidth = camera.ViewportSize.X
	for frame, ratio in scrollbarRatios do
		if frame and frame.Parent then
			frame.ScrollBarThickness = currentWidth * ratio
		else
			scrollbarRatios[frame] = nil
		end
	end
end

function Local.isMobileLayoutActive(): boolean
	return UserInputService.TouchEnabled and camera.ViewportSize.X >= MOBILE_MIN_VIEWPORT_X
end

function Local.updateMobileLayout()
	local shouldBeMobile = Local.isMobileLayoutActive()
	if shouldBeMobile == isMobileLayout then return end
	isMobileLayout = shouldBeMobile
	Shared.IsMobileLayout = shouldBeMobile

	for _, entry in MOBILE_LAYOUT_OVERRIDES do
		local gui = Shared.Guis[entry.gui]
		local element = gui and gui:FindFirstChild(entry.element)
		local original = element and originalLayout[element]
		if not element or not original then continue end

		if shouldBeMobile then
			if entry.position then element.Position = entry.position end
			if entry.size then element.Size = entry.size end
		else
			element.Position = original.position
			element.Size = original.size
		end
	end

	Shared.OnMobileLayoutChanged:Fire(shouldBeMobile)
end

function Local.updateTouchDevice()
	local isTouch = UserInputService.PreferredInput == Enum.PreferredInput.Touch
	if isTouch == Shared.IsTouchDevice then return end
	Shared.IsTouchDevice = isTouch
	Shared.OnTouchDeviceChanged:Fire(isTouch)
end

function Local.hideAllGuis(includeIgnore: boolean?)
	for _, gui in Shared.Guis do
		if not gui then continue end
		if not includeIgnore and table.find(ignored, gui) then continue end
		if gui:GetAttribute("Ignored") == true then continue end
		gui.Enabled = false
	end
end

function Local.openAllIgnoredGuis()
	for _, gui in ignored do
		if not gui then continue end
		gui.Enabled = true
	end
end

function Local.addFrameButton(frame: GuiObject)
	if not frame or not frame:IsDescendantOf(player) then return end
	local button = frame:FindFirstChild("Button") :: GuiButton
	if not button and frame:IsA("GuiButton") then
		button = frame
	end

	local uiScale = frame:FindFirstChild("UIScale") or Instance.new("UIScale")
	uiScale.Parent = frame

	if not frameConns[frame] then
		frameConns[frame] = {}
	end

	table.insert(frameConns[frame], frame.MouseEnter:Connect(function()
		Shared.TweenScale(uiScale, 1.1, .1)
	end))

	table.insert(frameConns[frame], button.MouseLeave:Connect(function()
		Shared.TweenScale(uiScale, 1, .1)
	end))

	table.insert(frameConns[frame], button.Activated:Connect(function()
		Shared.TweenScale(uiScale, .85, .1)
		task.wait(.1)
		Shared.TweenScale(uiScale, 1, .1)
	end))

	table.insert(frameConns[frame], frame.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			for _, conn in frameConns[frame] do
				conn:Disconnect()
			end
			frameConns[frame] = nil
		end
	end))
end

--[[ Public Functions ]]--

function Shared.Typewrite(label: TextLabel, text: string, speed: number?): number
	local default_speed = 0.02
	local duration = #text * (speed or default_speed)

	task.spawn(function()
		label.Text = ""
		for i = 1, #text do
			label.Text = string.sub(text, 1, i)
			task.wait(speed or default_speed)
		end
	end)

	return duration
end

function Shared.TweenScale(uiScale: UIScale, scale: number, speed: number?)
	TweenService:Create(uiScale, TweenInfo.new(speed or 0.1, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Scale = scale }):Play()
end

function Shared.SwitchActiveGui(guiName: string, force: boolean?)
	local gui = Shared.Guis[guiName]
	if not gui then return end

	if activeGuiName == guiName then
		Shared.RestoreGuis()
		return
	end

	Local.hideAllGuis(force)
	gui.Enabled = true
	activeGuiName = guiName
	Shared.onActiveGuiChanged:Fire(guiName)
end

function Shared.HideActiveGui()
	Local.hideAllGuis(true)
	activeGuiName = nil
end

function Shared.RestoreGuis()
	Local.hideAllGuis(true)
	Local.openAllIgnoredGuis()
	activeGuiName = nil
	Shared.onActiveGuiChanged:Fire(nil)
end

function Shared.HideAllGuis()
	Local.hideAllGuis(true)
	activeGuiName = nil
	Shared.onActiveGuiChanged:Fire(nil)
end

return Shared
