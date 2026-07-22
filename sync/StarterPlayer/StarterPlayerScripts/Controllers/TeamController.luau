--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local player = Players.LocalPlayer

--|| Variables
local _localTeam: string? = nil
local _networkConnections: {Network.Cleanup} = {}

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Team", "Assigned", function(data: {teamName: string?})
		Local.OnTeamAssigned(data.teamName)
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.OnTeamAssigned(teamName: string?)
	_localTeam = teamName

	Network:FireLocal("Team", "Assigned", { teamName = teamName })
end

-- [[ Public Functions ]] --
function Shared.GetLocalTeam(): string?
	return _localTeam
end

function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared