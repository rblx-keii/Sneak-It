--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local DataService = require(script.Parent.DataService)
local Network = require(ReplicatedStorage.Modules.Network)
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

--|| Types
type Team = "Smuggler" | "TSA"
type RoundEarnings = { playtime: number, teamTask: number }

--|| Variables
local _playtimeThreads: { [Player]: thread } = {}
local _connections: {RBXScriptConnection} = {}

-- This round's per-player earnings, broken down for the end-of-round rewards
-- screen. Reset when a player joins a round (Local.StartPlaytimeTracking),
-- read and cleared in Shared.GrantRoundRewards.
local _roundEarnings: { [Player]: RoundEarnings } = {}

--|| Constants
local WIN_REWARD = 50
local LOSS_REWARD = 15
local FIRST_WIN_OF_DAY_REWARD = 100
local PLAYTIME_REWARD = 5
local PLAYTIME_INTERVAL = 60 -- seconds

--|| MAIN ||--
local Local = {}
local Shared = {}

Shared.RoundEvents = {
	OnParticipantJoined = ModuleUtils.signal.new() :: typeof(ModuleUtils.signal.new()),
	OnParticipantLeft = ModuleUtils.signal.new() :: typeof(ModuleUtils.signal.new())
}

-- [[ Startup ]] --
function Shared.Init()
	Shared.RoundEvents.OnParticipantJoined:Connect(Local.StartPlaytimeTracking)
	Shared.RoundEvents.OnParticipantLeft:Connect(Local.StopPlaytimeTracking)

	table.insert(_connections, Players.PlayerRemoving:Connect(function(player: Player)
		_roundEarnings[player] = nil
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --

function Local.StartPlaytimeTracking(player: Player)
	Local.StopPlaytimeTracking(player)
	_roundEarnings[player] = { playtime = 0, teamTask = 0 }

	_playtimeThreads[player] = task.spawn(function()
		while true do
			task.wait(PLAYTIME_INTERVAL)
			DataService.UpdateData(player, { type = "AddCoins", data = { amount = PLAYTIME_REWARD } })

			local earnings = _roundEarnings[player]
			if earnings then
				earnings.playtime += PLAYTIME_REWARD
			end
		end
	end)
end

function Local.StopPlaytimeTracking(player: Player)
	local thread = _playtimeThreads[player]
	if thread then
		task.cancel(thread)
		_playtimeThreads[player] = nil
	end
end

function Local.GrantFirstWinOfDay(player: Player)
	local data = DataService.GetData(player)
	if not data then return end

	local today = os.date("!%Y-%m-%d")
	if data.profile.lastWinDate == today then return end

	DataService.UpdateData(player, { type = "AddCoins", data = { amount = FIRST_WIN_OF_DAY_REWARD } })
	DataService.UpdateData(player, { type = "SetLastWinDate", data = { date = today } })
end

-- [[ Public Functions ]] --

-- Called by ArrestService/DepositService when a player completes a
-- team-based task (a TSA arrest, a Smuggler deposit). Grants the coins and
-- tracks them toward this round's "Team Based Tasks Earned" total.
function Shared.GrantTeamTaskReward(player: Player, amount: number)
	if not DataService.IsDataLoaded(player) then return end

	DataService.UpdateData(player, { type = "AddCoins", data = { amount = amount } })

	local earnings = _roundEarnings[player]
	if earnings then
		earnings.teamTask += amount
	end
end

-- Called by RoundService at round end
function Shared.GrantRoundRewards(winningTeam: Team, participants: { [Player]: Team })
	for player, team in participants do
		if not DataService.IsDataLoaded(player) then continue end

		local didWin = team == winningTeam
		local baseReward = didWin and WIN_REWARD or LOSS_REWARD
		local earnings = _roundEarnings[player] or { playtime = 0, teamTask = 0 }

		DataService.UpdateData(player, { type = "AddCoins", data = { amount = baseReward } })

		DataService.UpdateData(player, {
			type = "UpdateProfile",
			data = { key = "totalGamesPlayed", amount = 1 },
		})

		if didWin then
			DataService.UpdateData(player, {
				type = "UpdateProfile",
				data = { key = "totalWins", amount = 1 },
			})

			DataService.UpdateData(player, {
				type = "UpdateProfile",
				data = {
					key = team == "Smuggler" and "smugglerWins" or "tsaWins",
					amount = 1,
				},
			})

			Local.GrantFirstWinOfDay(player)
		end

		-- Fire the round's earnings breakdown to the client for the rewards screen
		Network:FireClient("Round", player, "RewardGranted", {
			playtimeTokens = earnings.playtime,
			teamTaskTokens = earnings.teamTask,
			baseReward = baseReward,
			totalTokens = earnings.playtime + earnings.teamTask + baseReward,
			didWin = didWin,
			team = team,
		})

		_roundEarnings[player] = nil
	end
end

function Shared.Destroy()
	for _, thread in _playtimeThreads do
		task.cancel(thread)
	end
	table.clear(_playtimeThreads)
	table.clear(_roundEarnings)

	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)
end

return Shared
