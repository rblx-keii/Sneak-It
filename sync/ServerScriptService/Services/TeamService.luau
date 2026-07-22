--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local DataService = require(script.Parent.DataService)

--|| Types
type TeamName = "TSA" | "Smuggler"

--|| Variables
local _teamCache: {[number]: string} = {}
local _connections: {RBXScriptConnection} = {}
local _networkConnections: {Network.Cleanup} = {}

--|| Constants
local TEAM_CONFIGS: {[string]: Color3} = {
	TSA = Color3.fromRGB(0, 100, 220),
	Smuggler = Color3.fromRGB(30, 180, 60)
}

local TEAM_NAMES: {TeamName} = { "TSA", "Smuggler" }

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Local.CreateTeams()

	table.insert(_connections, Players.PlayerRemoving:Connect(Local.OnPlayerRemoving))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.CreateTeams()
	for teamName, teamColor in TEAM_CONFIGS do
		if not Teams:FindFirstChild(teamName) then
			local team = Instance.new("Team")
			team.Name = teamName
			team.TeamColor = BrickColor.new(teamColor)
			team.AutoAssignable = false
			team.Parent = Teams
		end
	end
end

function Local.GetTeamPlayerCount(teamName: string): number
	local team = Teams:FindFirstChild(teamName)
	return team and #team:GetPlayers() or 0
end

-- Sourced from profile.Data.afk, not a player attribute. Treats unloaded
-- data as not-AFK rather than excluding a player whose profile hasn't synced.
function Local.IsAfk(player: Player): boolean
	if not DataService.IsDataLoaded(player) then
		return false
	end

	local data = DataService.GetData(player)
	return data ~= nil and data.afk == true
end

function Shared.IsAfk(player: Player): boolean
	return Local.IsAfk(player)
end

function Local.PickBalancedTeam(): string
	local lowest: string? = nil
	local tied: {string} = {}

	for _, teamName in TEAM_NAMES do
		local count = Local.GetTeamPlayerCount(teamName)

		if lowest == nil or count < Local.GetTeamPlayerCount(lowest) then
			lowest = teamName
			tied = { teamName }
		elseif count == Local.GetTeamPlayerCount(lowest) then
			table.insert(tied, teamName)
		end
	end

	return tied[math.random(1, #tied)]
end

-- Sets player.Team and notifies the client. Does not spawn — spawning is
-- owned by RoundStateService/SpawnService once a map actually exists.
function Local.AssignPlayer(player: Player, teamName: string)
	local team = Teams:FindFirstChild(teamName)
	if not team then
		warn(`[TeamService] Team "{teamName}" does not exist`)
		return
	end

	player.Team = team
	_teamCache[player.UserId] = teamName

	Network:FireClient("Team", player, "Assigned", { teamName = teamName })
end

function Local.OnPlayerRemoving(player: Player)
	_teamCache[player.UserId] = nil
end

-- [[ Public Functions ]] --

-- Reverts a player to no team (lobby/spectator). Notifies the client via the
-- same "Assigned" event so TeamController's local team state stays in sync.
function Shared.SetNeutral(player: Player)
	player.Team = nil :: any
	_teamCache[player.UserId] = nil

	Network:FireClient("Team", player, "Assigned", { teamName = nil })
end

-- Fresh balanced split across TSA/Smuggler for a given player pool. AFK
-- players are filtered out and absent from the returned roster.
function Shared.AssignTeams(players: {Player}): {[string]: {Player}}
	local roster: {[string]: {Player}} = {}
	for _, teamName in TEAM_NAMES do
		roster[teamName] = {}
	end

	local eligible: {Player} = {}
	for _, player in players do
		if not Local.IsAfk(player) then
			table.insert(eligible, player)
		end
	end

	local shuffled = table.clone(eligible)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	local half = math.ceil(#shuffled / 2)
	for i, player in shuffled do
		local teamName = i <= half and TEAM_NAMES[1] or TEAM_NAMES[2]
		Local.AssignPlayer(player, teamName)
		table.insert(roster[teamName], player)
	end

	return roster
end

-- Balanced single-player assignment (e.g. a mid-round RequestJoin). Returns
-- nil and assigns nothing if the player is AFK.
function Shared.AssignSinglePlayer(player: Player): string?
	if Local.IsAfk(player) then
		return nil
	end

	local teamName = Local.PickBalancedTeam()
	Local.AssignPlayer(player, teamName)
	return teamName
end

function Shared.GetTeam(player: Player): string?
	return _teamCache[player.UserId]
end

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared