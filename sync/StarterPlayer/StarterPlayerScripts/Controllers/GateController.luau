-- Client mirror of GateService's Workspace attributes (GateStage/
-- GateTimeLeft/BoardingOpen) -- same read-only-attribute pattern as
-- RoundController, so Hud (or any future in-world signage/PA prop script)
-- goes through here instead of touching Workspace directly.
--|| Services
local Workspace = game:GetService("Workspace")

--|| References
local ModuleUtils = require(game:GetService("ReplicatedStorage").Modules.Utils.ModuleUtils)

--|| Types
export type GateStage = "Arrived" | "Boarding" | "Departing" | "Waiting"

--|| Variables
local _attributeConnections: {RBXScriptConnection} = {}

--|| Constants
local ATTR_STAGE = "GateStage"
local ATTR_TIME_LEFT = "GateTimeLeft"
local ATTR_BOARDING_OPEN = "BoardingOpen"

--|| MAIN ||--
local Local = {}
local Shared = {}

--[[ Signals ]]--
Shared.OnStageChanged = ModuleUtils.signal.new()
Shared.OnTimeLeftChanged = ModuleUtils.signal.new()
Shared.OnBoardingOpenChanged = ModuleUtils.signal.new()

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_attributeConnections, Workspace:GetAttributeChangedSignal(ATTR_STAGE):Connect(function()
		Shared.OnStageChanged:Fire(Shared.GetStage())
	end))

	table.insert(_attributeConnections, Workspace:GetAttributeChangedSignal(ATTR_TIME_LEFT):Connect(function()
		Shared.OnTimeLeftChanged:Fire(Shared.GetTimeLeft())
	end))

	table.insert(_attributeConnections, Workspace:GetAttributeChangedSignal(ATTR_BOARDING_OPEN):Connect(function()
		Shared.OnBoardingOpenChanged:Fire(Shared.IsBoardingOpen())
	end))
end

function Shared.Start()

end

-- [[ Public Functions ]] --
function Shared.GetStage(): GateStage?
	return Workspace:GetAttribute(ATTR_STAGE)
end

function Shared.GetTimeLeft(): number
	return Workspace:GetAttribute(ATTR_TIME_LEFT) or 0
end

function Shared.IsBoardingOpen(): boolean
	return Workspace:GetAttribute(ATTR_BOARDING_OPEN) == true
end

function Shared.Destroy()
	for _, conn in _attributeConnections do
		conn:Disconnect()
	end
	table.clear(_attributeConnections)
end

return Shared
