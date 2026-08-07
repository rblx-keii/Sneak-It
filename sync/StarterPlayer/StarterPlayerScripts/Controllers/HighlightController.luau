--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

--|| Types
type HighlightSession = {
	highlight: Highlight,
	pulseThread: thread?,
	watchThread: thread?
}

--|| Variables
local _activeSessions: {[Model]: HighlightSession} = {}
local _networkConnections: {Network.Cleanup} = {}

--|| Constants
local HIGHLIGHT_FILL_COLOR = Color3.fromRGB(255, 80, 80)
local HIGHLIGHT_OUTLINE_COLOR = Color3.fromRGB(255, 30, 30)
local HIGHLIGHT_FILL_TRANSPARENCY_VISIBLE = 0.4
local HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN = 1
local PULSE_INTERVAL = 3
local PULSE_FADE_IN_TIME = 0.3
local PULSE_FADE_OUT_TIME = 0.5

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Highlight", "Start", function(data: { targetCharacter: Model })
		Local.StartHighlight(data and data.targetCharacter)
	end))

	table.insert(_networkConnections, Network:BindEvent("Highlight", "Stop", function(data: { targetCharacter: Model })
		Local.StopHighlight(data and data.targetCharacter)
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.StartHighlight(character: Model?)
	if not character then return end
	if _activeSessions[character] then return end

	local highlight = Instance.new("Highlight")
	highlight.FillColor = HIGHLIGHT_FILL_COLOR
	highlight.OutlineColor = HIGHLIGHT_OUTLINE_COLOR
	highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN
	highlight.OutlineTransparency = 0
	highlight.Adornee = character
	highlight.Parent = character

	local session: HighlightSession = {
		highlight = highlight,
		pulseThread = nil,
		watchThread = nil
	}

	_activeSessions[character] = session

	session.pulseThread = task.spawn(function()
		while _activeSessions[character] do
			local fadeIn = TweenService:Create(
				highlight,
				TweenInfo.new(PULSE_FADE_IN_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
				{ FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_VISIBLE }
			)
			fadeIn:Play()
			fadeIn.Completed:Wait()

			task.wait(0.2)

			local fadeOut = TweenService:Create(
				highlight,
				TweenInfo.new(PULSE_FADE_OUT_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
				{ FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN }
			)
			fadeOut:Play()
			fadeOut.Completed:Wait()

			task.wait(PULSE_INTERVAL - PULSE_FADE_IN_TIME - PULSE_FADE_OUT_TIME - 0.2)
		end
	end)
end

function Local.StopHighlight(character: Model?)
	if not character then return end

	local session = _activeSessions[character]
	if not session then return end

	if session.pulseThread then
		task.cancel(session.pulseThread)
		session.pulseThread = nil
	end

	if session.watchThread then
		task.cancel(session.watchThread)
		session.watchThread = nil
	end

	if session.highlight and session.highlight.Parent then
		local fadeOut = TweenService:Create(
			session.highlight,
			TweenInfo.new(PULSE_FADE_OUT_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
			{ FillTransparency = 1 }
		)
		fadeOut:Play()
		fadeOut.Completed:Connect(function()
			if session.highlight and session.highlight.Parent then
				session.highlight:Destroy()
			end
		end)
	end

	_activeSessions[character] = nil
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for character, _ in _activeSessions do
		Local.StopHighlight(character)
	end

	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared
