--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local InputController = require(ReplicatedStorage.Modules.Shared.InputController)

local player = Players.LocalPlayer

--|| Variables
local _sprintHandle: InputController.ActionHandle? = nil
local _isSprinting: boolean = false

--|| Constants
local SPRINT_ACTION = "Sprint"
local SPRINT_KEYS = { Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift }

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	_sprintHandle = InputController.BindAction({
		name = SPRINT_ACTION,
		keys = SPRINT_KEYS,
		priority = Enum.ContextActionPriority.Default.Value,
		callback = Local.OnSprintInput
	})
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.OnSprintInput(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
	if state == Enum.UserInputState.Begin then
		if _isSprinting then return Enum.ContextActionResult.Pass end
		_isSprinting = true
		Network:FireServer(SPRINT_ACTION, "Start")
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if not _isSprinting then return Enum.ContextActionResult.Pass end
		_isSprinting = false
		Network:FireServer(SPRINT_ACTION, "Stop")
	end

	return Enum.ContextActionResult.Pass
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	if _sprintHandle then
		_sprintHandle:Unbind()
		_sprintHandle = nil
	end

	if _isSprinting then
		_isSprinting = false
		Network:FireServer(SPRINT_ACTION, "Stop")
	end
end

return Shared
