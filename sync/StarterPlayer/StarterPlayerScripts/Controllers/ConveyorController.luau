--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)
local ProximityPrompt = require(ReplicatedStorage.Modules.Shared.Classes.ProximityPrompt)

--|| Variables
local _activePrompts: {[BasePart]: ProximityPrompt.ClassType} = {}

--|| Constants
local PLACE_ZONE_TAG = "ConveyorPlaceZone"

local MAX_INTERACT_DISTANCE = 10
local INTERACT_HOLD_DURATION = 0.3

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Observers.observeTag(PLACE_ZONE_TAG, function(part): (() -> ())?
		task.spawn(Local.SetupPrompt, part, "Place Item", "Place")

		return function()
			task.spawn(Local.TeardownPrompt, part)
		end
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetupPrompt(part: Instance, actionText: string, requestKey: string)
	if not part:IsA("BasePart") then return end
	if _activePrompts[part] then return end

	local prompt = ProximityPrompt.new({
		name = `Conveyor_{requestKey}_{part:GetFullName()}`,
		actionText = actionText,
		objectText = "Conveyor Belt",
		holdDuration = INTERACT_HOLD_DURATION,
		maxActivationDistance = MAX_INTERACT_DISTANCE,
		enabled = true,
		keyboardKeyCode = Enum.KeyCode.E,
		gamepadKeyCode = Enum.KeyCode.ButtonX,
		parent = part,
	})

	prompt.Triggered:Connect(function()
		Network:FireServer("Conveyor", requestKey, { node = part })
	end)

	_activePrompts[part :: BasePart] = prompt
end

function Local.TeardownPrompt(part: Instance)
	local prompt = _activePrompts[part :: BasePart]
	if not prompt then return end

	prompt:Destroy()
	_activePrompts[part :: BasePart] = nil
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, prompt in _activePrompts do
		prompt:Destroy()
	end
	table.clear(_activePrompts)
end

return Shared
