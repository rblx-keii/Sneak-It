--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local CheckpointAlert = require(script.Parent.Gui.CheckpointAlert)

--|| Variables
local _networkConnections: {Network.Cleanup} = {}

local Local = {}
local Shared = {}

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Checkpoint", "Alarm", function(data: { playerId: number, position: Vector3, message: string? })
		if data and data.message then
			CheckpointAlert.ShowAlert(data.message)
		end
	end))
end

function Shared.Start()

end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared
