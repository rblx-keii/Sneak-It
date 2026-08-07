--|| Services
local RunService = game:GetService("RunService")

--|| References
local GuiController = require(script.Parent.Parent.GuiController)

local Gui = GuiController.Guis.Alarm
local List = Gui.List :: Frame
local Template = List.Template :: Frame
Template.Visible = false

--|| Variables
local _activeFrames: {Frame} = {}
local _fadeConnections: {[Frame]: RBXScriptConnection} = {}

local Local = {}
local Shared = {}

--|| Constants
local DISPLAY_DURATION = 4
local FADE_DURATION = 0.35

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()

end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.EaseCubicOut(t: number): number
	return 1 - math.pow(1 - t, 3)
end

function Local.SetTransparency(frame: Frame, alpha: number)
	local content = frame:FindFirstChild("Content") :: Frame?
	local label = content and (content:FindFirstChild("Label") :: TextLabel?)
	if not label then return end

	label.TextTransparency = alpha

	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = alpha
	end
end

function Local.RunFade(frame: Frame, fromAlpha: number, toAlpha: number, onComplete: (() -> ())?)
	if _fadeConnections[frame] then
		_fadeConnections[frame]:Disconnect()
	end

	local elapsed = 0
	_fadeConnections[frame] = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local t = Local.EaseCubicOut(math.clamp(elapsed / FADE_DURATION, 0, 1))
		Local.SetTransparency(frame, fromAlpha + (toAlpha - fromAlpha) * t)

		if t >= 1 then
			_fadeConnections[frame]:Disconnect()
			_fadeConnections[frame] = nil
			if onComplete then onComplete() end
		end
	end)
end

-- [[ Public Functions ]] --
function Shared.ShowAlert(message: string)
	local clone = Template:Clone()
	clone.Visible = true
	clone.Parent = List

	local content = clone:FindFirstChild("Content") :: Frame?
	local label = content and (content:FindFirstChild("Label") :: TextLabel?)
	if label then
		label.Text = message
	end

	table.insert(_activeFrames, clone)

	Local.SetTransparency(clone, 1)
	Local.RunFade(clone, 1, 0)

	task.delay(DISPLAY_DURATION, function()
		if not clone.Parent then return end

		Local.RunFade(clone, 0, 1, function()
			local index = table.find(_activeFrames, clone)
			if index then
				table.remove(_activeFrames, index)
			end
			clone:Destroy()
		end)
	end)
end

function Shared.Destroy()
	for _, conn in _fadeConnections do
		conn:Disconnect()
	end
	table.clear(_fadeConnections)

	for _, frame in _activeFrames do
		frame:Destroy()
	end
	table.clear(_activeFrames)
end

return Shared
