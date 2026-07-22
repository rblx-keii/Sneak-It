--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)

local player = Players.LocalPlayer

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _isLocked: boolean = false

--|| Constants

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Jail", "LockMovement", function(_data: any)
		Local.LockMovement()
	end))

	table.insert(_networkConnections, Network:BindEvent("Jail", "UnlockMovement", function(_data: any)
		Local.UnlockMovement()
	end))

	Observers.observeCharacter(function(_player: Player, character: Model): (() -> ())? 
		if _player ~= player then return end
		
		return function()
			Local.UnlockMovement()
		end
	end)
end

function Shared.Start()
	
end

-- [[ Private Functions ]] --
function Local.LockMovement()
	if _isLocked then return end
	_isLocked = true

	local playerScripts = player:WaitForChild("PlayerScripts")
	local playerModule = playerScripts:WaitForChild("PlayerModule")
	local controlModule = playerModule:WaitForChild("ControlModule")
	local controls = require(playerModule):GetControls()
	controls:Disable()
end

function Local.UnlockMovement()
	if not _isLocked then return end
	_isLocked = false

	local playerScripts = player:WaitForChild("PlayerScripts")
	local playerModule = playerScripts:WaitForChild("PlayerModule")
	local controlModule = playerModule:WaitForChild("ControlModule")
	local controls = require(playerModule):GetControls()
	controls:Enable(true)
end

-- [[ Public Functions ]] --
function Shared.IsLocked(): boolean
	return _isLocked
end

Shared.LockMovement = Local.LockMovement
Shared.UnlockMovement = Local.UnlockMovement

function Shared.Destroy()
	Local.UnlockMovement()

	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared