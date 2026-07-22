--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

--|| References
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: typeof(StarterGui)
local camera = workspace.CurrentCamera

--|| Constants
local BASE_WIDTH = 1920
local MIN_RATIO = 0.01

--|| Variables
local activeGuiName = nil
local frameConns = {}
local ignored = {}
local scrollbarRatios = {}

--|| MAIN ||--
local Local = {}
local Shared = {}

Shared.Priority = -1

--[[ Signals ]]--
Shared.onActiveGuiChanged = ModuleUtils.signal.new()

--[[ GUIS ]]--

Shared.Guis = {
	Cursor = playerGui:WaitForChild("Cursor") :: typeof(StarterGui.Cursor),
	Hotbar = playerGui:WaitForChild("Hotbar") :: typeof(StarterGui.Hotbar),
	Hud = playerGui:WaitForChild("Hud") :: typeof(StarterGui.Hud),
	Interact = playerGui:WaitForChild("Interact") :: typeof(StarterGui.Interact),
	Inventory = playerGui:WaitForChild("Inventory") :: typeof(StarterGui.Inventory),
	Items = playerGui:WaitForChild("Items") :: typeof(StarterGui.Items),
	Perks = playerGui:WaitForChild("Perks") :: typeof(StarterGui.Perks),
	Quest = playerGui:WaitForChild("Quests") :: typeof(StarterGui.Quests),
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

	for _, frame in CollectionService:GetTagged("FrameButton") do
		Local.addFrameButton(frame)
	end

	CollectionService:GetInstanceAddedSignal("FrameButton"):Connect(Local.addFrameButton)

	for _, frame in CollectionService:GetTagged("ExitButton") do
		if not frame or not frame:IsDescendantOf(player) then continue end
		local button = frame:FindFirstChild("Button") :: GuiButton

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
