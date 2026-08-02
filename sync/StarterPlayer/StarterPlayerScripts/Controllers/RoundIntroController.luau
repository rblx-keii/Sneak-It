--|| Services
local Players = game:GetService("Players")

--|| References
local GuiController = require(script.Parent.GuiController)
local RoundController = require(script.Parent.RoundController)
local CameraController = require(script.Parent.CameraController)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--|| Types
type RoundState = RoundController.RoundState

type Phase = {
	guiName: string,
	caption: string,
}

--|| Variables
local _connections: { RBXScriptConnection } = {}
local _stateId = 0
local _introActive = false

local _overlayGui: ScreenGui? = nil
local _captionLabel: TextLabel? = nil
local _countdownLabel: TextLabel? = nil

--|| Constants
local PHASE_DURATION = 10
local DIM_TRANSPARENCY = 0.45
local PROMPT_FONT = Font.new("rbxassetid://11702779517", Enum.FontWeight.Bold, Enum.FontStyle.Normal)

-- Placeholder overlay/label styling — swap for dedicated Studio elements once the UI dev has time.
local PHASES: { Phase } = {
	{ guiName = "Perks", caption = "Equip a Perk" },
	{ guiName = "Inventory", caption = "Choose Your Items" },
}

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Local.BuildOverlay()

	table.insert(_connections, RoundController.OnStateChanged:Connect(Local.OnStateChanged))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.BuildOverlay()
	local overlay = Instance.new("ScreenGui")
	overlay.Name = "RoundIntroOverlay"
	overlay.ResetOnSpawn = false
	overlay.IgnoreGuiInset = true
	overlay.DisplayOrder = -1
	overlay.Enabled = false

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = DIM_TRANSPARENCY
	dim.BorderSizePixel = 0
	dim.Parent = overlay

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.AnchorPoint = Vector2.new(0.5, 1)
	caption.Position = UDim2.fromScale(0.5, 0.88)
	caption.Size = UDim2.fromScale(0.6, 0.06)
	caption.BackgroundTransparency = 1
	caption.TextScaled = true
	caption.FontFace = PROMPT_FONT
	caption.TextColor3 = Color3.new(1, 1, 1)
	caption.Text = ""
	caption.Parent = overlay

	local captionStroke = Instance.new("UIStroke")
	captionStroke.Thickness = 2
	captionStroke.Color = Color3.new(0, 0, 0)
	captionStroke.Parent = caption

	local countdown = Instance.new("TextLabel")
	countdown.Name = "Countdown"
	countdown.AnchorPoint = Vector2.new(0.5, 1)
	countdown.Position = UDim2.fromScale(0.5, 0.95)
	countdown.Size = UDim2.fromScale(0.2, 0.07)
	countdown.BackgroundTransparency = 1
	countdown.TextScaled = true
	countdown.FontFace = PROMPT_FONT
	countdown.TextColor3 = Color3.new(1, 1, 1)
	countdown.Text = ""
	countdown.Parent = overlay

	local countdownStroke = Instance.new("UIStroke")
	countdownStroke.Thickness = 2
	countdownStroke.Color = Color3.new(0, 0, 0)
	countdownStroke.Parent = countdown

	overlay.Parent = playerGui

	_overlayGui = overlay
	_captionLabel = caption
	_countdownLabel = countdown
end

function Local.RunPhase(tid: number, phase: Phase): boolean
	if _stateId ~= tid then return false end

	local gui = GuiController.Guis[phase.guiName]
	if not gui then return true end

	GuiController.HideAllGuis()
	gui.Enabled = true

	local frame = gui:FindFirstChild("Frame")
	local exitButton = frame and frame:FindFirstChild("Exit") :: GuiButton?
	if exitButton then exitButton.Active = false end

	if _captionLabel then _captionLabel.Text = phase.caption end

	local aborted = false
	for i = PHASE_DURATION, 1, -1 do
		if _stateId ~= tid then
			aborted = true
			break
		end
		if _countdownLabel then _countdownLabel.Text = `({i})` end
		task.wait(1)
	end

	if exitButton then exitButton.Active = true end

	return not aborted
end

function Local.RunIntro(tid: number)
	if _stateId ~= tid then return end
	_introActive = true

	if _overlayGui then _overlayGui.Enabled = true end
	CameraController.SetSuppressed(true)

	for _, phase in PHASES do
		local completed = Local.RunPhase(tid, phase)
		if not completed then break end
	end

	if _overlayGui then _overlayGui.Enabled = false end

	if _stateId == tid then
		GuiController.RestoreGuis()
	end

	CameraController.SetSuppressed(false)
	_introActive = false
end

function Local.OnStateChanged(newState: RoundState)
	if newState == "Starting" and player.Team ~= nil then
		_stateId += 1
		local tid = _stateId
		task.spawn(Local.RunIntro, tid)
		return
	end

	_stateId += 1

	if _introActive then
		if _overlayGui then _overlayGui.Enabled = false end
		GuiController.RestoreGuis()
		_introActive = false
		CameraController.SetSuppressed(false)
	end
end

-- [[ Public Functions ]] --
function Shared.IsActive(): boolean
	return _introActive
end

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	if _overlayGui then
		_overlayGui:Destroy()
		_overlayGui = nil
	end
end

return Shared
