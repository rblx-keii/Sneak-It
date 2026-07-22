--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

--|| Types
export type RoundState = "Waiting" | "Intermission" | "MapLoading" | "Starting" | "InProgress" | "Ended"

export type RewardBreakdown = {
	playtimeTokens: number, -- Playtime Tokens Earned
	teamTaskTokens: number, -- Team Based Tasks Earned (TSA arrests / Smuggler deposits)
	baseReward: number, -- Base Win/Lose Token Reward
	totalTokens: number, -- Total Tokens Earned
	didWin: boolean,
	team: string,
}

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _attributeConnections: {RBXScriptConnection} = {}
local _isPlaying = false

--|| Constants
local ATTR_STATE = "RoundState"
local ATTR_TIME_LEFT = "TimeLeft"
local ATTR_QUOTA_TOTAL = "QuotaTotal"

--|| MAIN ||--
local Local = {}
local Shared = {}

--[[ Signals ]]--
Shared.OnStateChanged = ModuleUtils.signal.new()
Shared.OnTimeLeftChanged = ModuleUtils.signal.new()
Shared.OnQuotaChanged = ModuleUtils.signal.new()
Shared.OnRoundEnded = ModuleUtils.signal.new()
Shared.OnRewardGranted = ModuleUtils.signal.new()
Shared.OnPlayingChanged = ModuleUtils.signal.new()

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_attributeConnections, Workspace:GetAttributeChangedSignal(ATTR_STATE):Connect(function()
		Shared.OnStateChanged:Fire(Shared.GetState())
	end))

	table.insert(_attributeConnections, Workspace:GetAttributeChangedSignal(ATTR_TIME_LEFT):Connect(function()
		Shared.OnTimeLeftChanged:Fire(Shared.GetTimeRemaining())
	end))

	table.insert(_attributeConnections, Workspace:GetAttributeChangedSignal(ATTR_QUOTA_TOTAL):Connect(function()
		Shared.OnQuotaChanged:Fire(Shared.GetQuotaTotal())
	end))

	table.insert(_networkConnections, Network:BindEvent("Round", "RoundEnded", function(data: { winner: string, quota: number })
		Local.SetPlaying(false)
		Shared.OnRoundEnded:Fire(data.winner, data.quota)
	end))

	table.insert(_networkConnections, Network:BindEvent("Round", "RewardGranted", function(data: RewardBreakdown)
		Shared.OnRewardGranted:Fire(data)
	end))

	-- Fired whenever the local player's team assignment changes -- covers the
	-- normal round-start roster (TeamService.AssignTeams), a mid-round
	-- RequestJoin (TeamService.AssignSinglePlayer), and the post-round reset
	-- back to no team (TeamService.SetNeutral). This is the single reliable
	-- "is the player currently playing" signal; the "Round"/"Join" event only
	-- reaches late-connecting/mid-round joiners, not everyone.
	table.insert(_networkConnections, Network:BindEvent("Team", "Assigned", function(data: { teamName: string? })
		Local.SetPlaying(data.teamName ~= nil)
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetPlaying(playing: boolean)
	if _isPlaying == playing then return end
	_isPlaying = playing
	Shared.OnPlayingChanged:Fire(playing)
end

-- [[ Public Functions ]] --
function Shared.IsPlaying(): boolean
	return _isPlaying
end

function Shared.GetState(): RoundState
	return (Workspace:GetAttribute(ATTR_STATE) :: RoundState?) or "Waiting"
end

function Shared.GetTimeRemaining(): number
	return Workspace:GetAttribute(ATTR_TIME_LEFT) or 0
end

function Shared.GetQuotaTotal(): number
	return Workspace:GetAttribute(ATTR_QUOTA_TOTAL) or 0
end

-- Requests to join the currently in-progress match as a latecomer. The
-- server no-ops this outside of "InProgress" (see RoundService.OnRequestJoin).
function Shared.RequestJoin()
	Network:FireServer("Round", "RequestJoin")
end

function Shared.Destroy()
	for _, conn in _attributeConnections do
		conn:Disconnect()
	end
	table.clear(_attributeConnections)

	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared
