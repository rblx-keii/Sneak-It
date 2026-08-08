--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local GuiController = require(script.Parent.Parent.GuiController)
local RoundController = require(script.Parent.Parent.RoundController)

local Gui = GuiController.Guis.Interact
local Template = Gui.Frame.Template
Template.Visible = false

--|| Variables
local _activePrompts: {[string]: Frame} = {}
local _activeConnections: {[Frame]: RBXScriptConnection} = {}
local _networkConnections: {Network.Cleanup} = {}
local _touchDeviceConn: any = nil

--|| Constants
local ANIM_DURATION = 0.35

local KEYCODE_IMAGES = {
	["Key_Q"] = "rbxassetid://76207542695716",
	["Key_F"] = "rbxassetid://114989395112655",
	["Key_G"] = "rbxassetid://91345836263241",
	["Key_E"] = "rbxassetid://86426194197515",
	["Key_LeftAlt"] = "rbxassetid://83383493987758",
	["Key_T"] = "rbxassetid://98332076005906",
	["Mouse_MouseButton1"] = "rbxassetid://75575119773770",
	["Mouse_MouseButton2"] = "rbxassetid://109593773299815",
	["Key_ButtonL2"] = "rbxassetid://98297166203745"
}

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, RoundController.OnPlayingChanged:Connect(Local.SetInteractEnabled))

	-- Keyboard/mouse "press E"-style prompts don't mean anything once MobileControls' own touch
	-- overlay is up — tracks GuiController.IsTouchDevice (the same signal MobileControlsController
	-- uses for its own Gui.Enabled) rather than the viewport-based IsMobileLayout, since those two
	-- can disagree (e.g. a touch-only device below the mobile viewport width floor).
	_touchDeviceConn = GuiController.OnTouchDeviceChanged:Connect(function()
		Local.SetInteractEnabled(RoundController.IsPlaying())
	end)

	Local.SetInteractEnabled(RoundController.IsPlaying())
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetInteractEnabled(enabled: boolean)
	local shouldShow = enabled and not GuiController.IsTouchDevice
	Gui.Enabled = shouldShow

	if not shouldShow then
		Shared.HideAllPrompts()
	end
end

function Local.GetFormattedKey(key: Enum.KeyCode | Enum.UserInputType): string
	if typeof(key) == "EnumItem" then
		if key.EnumType == Enum.KeyCode then
			return `Key_{key.Name}`
		elseif key.EnumType == Enum.UserInputType then
			return `Mouse_{key.Name}`
		end
	end
	return "Unknown"
end

function Local.EaseCubicOut(t: number): number
	return 1 - math.pow(1 - t, 3)
end

function Local.SlideInInteract(frame: Frame)
	local content = frame:FindFirstChild("Content") :: Frame
	local background = frame:FindFirstChild("Background") :: Frame
	if not content or not background then return end

	local gradient = background:FindFirstChildWhichIsA("UIGradient")

	local startPos = UDim2.new(1.5, 0, 0.5, 0)
	local targetPos = UDim2.new(0.5, 0, 0.5, 0)
	local startOff = Vector2.new(1, 0)
	local targetOff = Vector2.new(0, 0)

	content.Position = startPos
	if gradient then gradient.Offset = startOff end

	if _activeConnections[frame] then
		_activeConnections[frame]:Disconnect()
	end

	local elapsed = 0
	_activeConnections[frame] = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local alpha = math.clamp(elapsed / ANIM_DURATION, 0, 1)
		local ease = Local.EaseCubicOut(alpha)

		content.Position = startPos:Lerp(targetPos, ease)
		if gradient then
			gradient.Offset = startOff:Lerp(targetOff, ease)
		end

		if alpha >= 1 then
			if _activeConnections[frame] then
				_activeConnections[frame]:Disconnect()
				_activeConnections[frame] = nil
			end
		end
	end)
end

function Local.SlideOutInteract(frame: Frame)
	local content = frame:FindFirstChild("Content") :: Frame
	local background = frame:FindFirstChild("Background") :: Frame
	if not content or not background then 
		frame:Destroy()
		return 
	end

	local gradient = background:FindFirstChildWhichIsA("UIGradient")

	local startPos = content.Position
	local targetPos = UDim2.new(1.5, 0, 0.5, 0)
	local startOff = gradient and gradient.Offset or Vector2.new(0, 0)
	local targetOff = Vector2.new(1, 0)

	if _activeConnections[frame] then
		_activeConnections[frame]:Disconnect()
	end

	local elapsed = 0
	_activeConnections[frame] = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local alpha = math.clamp(elapsed / ANIM_DURATION, 0, 1)
		local ease = Local.EaseCubicOut(alpha)

		content.Position = startPos:Lerp(targetPos, ease)
		if gradient then
			gradient.Offset = startOff:Lerp(targetOff, ease)
		end

		if alpha >= 1 then
			if _activeConnections[frame] then
				_activeConnections[frame]:Disconnect()
				_activeConnections[frame] = nil
			end
			frame:Destroy()
		end
	end)
end

-- [[ Public Functions ]] --
function Shared.ChangeActionText(key: Enum.KeyCode | Enum.UserInputType, newAction: string)
	local formattedKey = Local.GetFormattedKey(key)
	local frame = _activePrompts[formattedKey]
	if not frame then return end

	local content = frame:FindFirstChild("Content")
	if content then
		local actionLabel = content:FindFirstChild("Action") :: TextLabel
		if actionLabel then 
			actionLabel.Text = newAction 
		end
	end
end

function Shared.ShowPrompt(key: Enum.KeyCode | Enum.UserInputType, action: string)
	local formattedKey = Local.GetFormattedKey(key)

	if _activePrompts[formattedKey] then
		Shared.ChangeActionText(key, action)
		return
	end

	local clone = Template:Clone()
	clone.Name = formattedKey
	clone.Visible = true

	local content = clone:FindFirstChild("Content")
	if content then
		local actionLabel = content:FindFirstChild("Action") :: TextLabel
		local keyImage = content:FindFirstChild("Key") :: ImageLabel

		if actionLabel then actionLabel.Text = action end
		if keyImage then keyImage.Image = KEYCODE_IMAGES[formattedKey] or "" end
	end

	clone.Parent = Gui.Frame
	_activePrompts[formattedKey] = clone

	Local.SlideInInteract(clone)
end

function Shared.HidePrompt(key: Enum.KeyCode | Enum.UserInputType)
	local formattedKey = Local.GetFormattedKey(key)
	local frame = _activePrompts[formattedKey]

	if not frame then return end

	_activePrompts[formattedKey] = nil
	Local.SlideOutInteract(frame)
end

function Shared.HideAllPrompts()
	for formattedKey, frame in _activePrompts do
		_activePrompts[formattedKey] = nil
		Local.SlideOutInteract(frame)
	end
end

function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	if _touchDeviceConn then
		_touchDeviceConn:Disconnect()
		_touchDeviceConn = nil
	end

	for _, conn in _activeConnections do
		conn:Disconnect()
	end
	table.clear(_activeConnections)

	Shared.HideAllPrompts()
end

return Shared