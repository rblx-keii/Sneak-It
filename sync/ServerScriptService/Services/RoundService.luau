--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

local MapService = require(script.Parent.MapService)
local SpawnService = require(script.Parent.SpawnService)
local TeamService = require(script.Parent.TeamService)
local DataService = require(script.Parent.DataService)
local RewardService = require(script.Parent.RewardService)

--|| Types
export type RoundState = "Waiting" | "Intermission" | "MapLoading" | "Starting" | "InProgress" | "Ended"
export type TeamName = "TSA" | "Smuggler"

--|| Variables
local _state: RoundState = "Waiting"
local _stateId: number = 0

local _matchParticipants: {Player} = {}
local _quotaTotal: number = 0
local _emptyTeamCheckId: {[TeamName]: number} = {}
local _readyPlayers: {[Player]: boolean} = {} -- data-loaded players; source of truth over Players:GetPlayers()

local _connections: {RBXScriptConnection} = {}

local isStudio = RunService:IsStudio()

--|| Constants
local MIN_TOTAL_PLAYERS = isStudio and 1 or 2 -- TEMP: lowered from 2 for solo NPC AI testing, revert once done
local INTERMISSION_DURATION = isStudio and 5 or 10
local STARTING_DURATION = isStudio and 5 or 20
local ROUND_DURATION = isStudio and 120 or 600
local ENDED_DISPLAY_DURATION = 10 -- time to let reward stats display/animate before cleanup
local EMPTY_TEAM_GRACE = 10
local QUOTA_TARGET = 50

local TEAM_NAMES: {TeamName} = { "TSA", "Smuggler" }
local BARRICADE_NAME = "A-B"

local ATTR_STATE = "RoundState"
local ATTR_TIME_LEFT = "TimeLeft"
local ATTR_QUOTA_TOTAL = "QuotaTotal"

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Signals ]] --
Shared.OnStateChange = ModuleUtils.signal.new()

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, Players.PlayerAdded:Connect(Local.OnPlayerAdded))
	table.insert(_connections, Players.PlayerRemoving:Connect(Local.OnPlayerRemoving))

	table.insert(_connections, DataService.OnDataLoaded:Connect(Local.OnDataLoaded))
	table.insert(_connections, DataService.OnDataReleased:Connect(Local.OnDataReleased))

	Network:BindEvent("Round", "RequestJoin", function(player: Player)
		Local.OnRequestJoin(player)
	end)

	for _, player in Players:GetPlayers() do
		if DataService.IsDataLoaded(player) then
			Local.OnDataLoaded(player)
		end
	end
end

function Shared.Start()
	Shared.SetState("Waiting")
end

-- [[ Private Functions ]] --

function Local.NotifyJoin(player: Player, teamName: string?)
	Network:FireClient("Round", player, "Join", {
		state = _state,
		timeLeft = Workspace:GetAttribute(ATTR_TIME_LEFT),
		quotaTotal = _quotaTotal,
		team = teamName,
	})
end

function Local.OnDataLoaded(player: Player)
	_readyPlayers[player] = true

	if _state == "Waiting" then
		Local.CheckIntegrity()
	end
end

function Local.OnDataReleased(player: Player)
	_readyPlayers[player] = nil
end

function Local.GetEligiblePlayers(): {Player}
	local eligible: {Player} = {}

	for player in pairs(_readyPlayers) do
		if player:IsDescendantOf(Players) and not TeamService.IsAfk(player) then
			table.insert(eligible, player)
		end
	end

	return eligible
end

function Local.OnPlayerAdded(player: Player)
	if _state == "Waiting" then
		Local.CheckIntegrity()
	else
		Local.NotifyJoin(player, nil)
	end
end

function Local.OnRequestJoin(player: Player)
	if _state ~= "InProgress" then return end
	if not _readyPlayers[player] then return end
	if table.find(_matchParticipants, player) then return end

	local teamName = TeamService.AssignSinglePlayer(player)
	if not teamName then return end -- AFK

	table.insert(_matchParticipants, player)
	RewardService.RoundEvents.OnParticipantJoined:Fire(player)
	Local.OnTeamCountChanged(teamName :: TeamName)
	Local.NotifyJoin(player, teamName)

	task.defer(function()
		local activeMap = MapService.GetActiveMap()
		if activeMap and player.Character then
			SpawnService.SpawnPlayer(player, teamName)
		end
	end)
end

function Local.OnPlayerRemoving(player: Player)
	_readyPlayers[player] = nil

	local index = table.find(_matchParticipants, player)
	if index then
		table.remove(_matchParticipants, index)
		RewardService.RoundEvents.OnParticipantLeft:Fire(player)
	end

	if _state == "InProgress" then
		local teamName = TeamService.GetTeam(player)
		if teamName then
			Local.OnTeamCountChanged(teamName)
		end
	end

	if _state == "Waiting" then
		Local.CheckIntegrity()
	end
end

function Local.GetTeamPlayerCount(teamName: TeamName): number
	local count = 0
	for _, player in _matchParticipants do
		if TeamService.GetTeam(player) == teamName then
			count += 1
		end
	end
	return count
end

function Local.SetBarricadeLocked(locked: boolean)
	local activeMap = MapService.GetActiveMap()
	if not activeMap then return end

	local barricadesFolder = activeMap:FindFirstChild("Barricades")
	if not barricadesFolder then
		warn("[RoundStateService] Active map has no Barricades folder")
		return
	end

	local barricade = barricadesFolder:FindFirstChild(BARRICADE_NAME)
	if not barricade or not barricade:IsA("BasePart") then
		warn(`[RoundStateService] Barricade "{BARRICADE_NAME}" not found or not a BasePart`)
		return
	end

	barricade.CanCollide = locked
end

function Local.CheckIntegrity()
	if _state ~= "Waiting" then return end

	if #Local.GetEligiblePlayers() >= MIN_TOTAL_PLAYERS then
		Shared.SetState("Intermission")
	end
end

-- [[ Empty-Team Grace Period ]] --

function Local.GetOpposingTeam(teamName: string): "Smuggler" | "TSA"
	return (teamName == "TSA" and "Smuggler" or "TSA") :: any
end

function Local.NotifyEmptyTeamWarning(teamName: TeamName, graceSeconds: number)
	Network:FireAll("Round", "EmptyTeamWarning", {
		team = teamName,
		secondsRemaining = graceSeconds,
	})
end

function Local.NotifyEmptyTeamResolved(teamName: TeamName)
	Network:FireAll("Round", "EmptyTeamResolved", {
		team = teamName,
	})
end

function Local.StartEmptyTeamGrace(teamName: TeamName)
	_emptyTeamCheckId[teamName] = (_emptyTeamCheckId[teamName] or 0) + 1
	local checkId = _emptyTeamCheckId[teamName]
	local roundTid = _stateId

	Local.NotifyEmptyTeamWarning(teamName, EMPTY_TEAM_GRACE)

	task.delay(EMPTY_TEAM_GRACE, function()
		if _stateId ~= roundTid then return end
		if _emptyTeamCheckId[teamName] ~= checkId then return end

		Local.EndRound(Local.GetOpposingTeam(teamName))
	end)
end

function Local.OnTeamCountChanged(teamName: TeamName?)
	if not teamName then return end
	if _state ~= "InProgress" then return end

	local count = Local.GetTeamPlayerCount(teamName)

	if count == 0 then
		Local.StartEmptyTeamGrace(teamName)
	else
		_emptyTeamCheckId[teamName] = (_emptyTeamCheckId[teamName] or 0) + 1
		Local.NotifyEmptyTeamResolved(teamName)
	end
end

-- [[ Quota ]] --

function Shared.AddToQuota(amount: number)
	if _state ~= "InProgress" then return end

	_quotaTotal += amount
	Workspace:SetAttribute(ATTR_QUOTA_TOTAL, _quotaTotal)

	if _quotaTotal >= QUOTA_TARGET then
		Local.EndRound("Smuggler")
	end
end

-- [[ Round End ]] --

function Local.EndRound(winner: TeamName)
	if _state ~= "InProgress" then return end
	Shared.SetState("Ended")

	Network:FireAll("Round", "RoundEnded", { winner = winner, quota = _quotaTotal })

	local participants: { [Player]: TeamName } = {}
	for _, player in _matchParticipants do
		local teamName = TeamService.GetTeam(player)
		if teamName then
			participants[player] = teamName :: TeamName
		end
	end

	RewardService.GrantRoundRewards(winner, participants)
end

-- [[ State Handlers ]] --

function Local.HandleWaiting(tid: number)
	_matchParticipants = {}
	_quotaTotal = 0
	table.clear(_emptyTeamCheckId)

	Workspace:SetAttribute(ATTR_QUOTA_TOTAL, 0)
	Workspace:SetAttribute(ATTR_TIME_LEFT, nil)

	Local.CheckIntegrity()
end

function Local.HandleIntermission(tid: number)
	for i = INTERMISSION_DURATION, 0, -1 do
		if _stateId ~= tid then return end
		Workspace:SetAttribute(ATTR_TIME_LEFT, i)
		task.wait(1)
	end

	if _stateId ~= tid then return end

	if #Local.GetEligiblePlayers() < MIN_TOTAL_PLAYERS then
		Shared.SetState("Waiting")
		return
	end

	Shared.SetState("MapLoading")
end

function Local.HandleMapLoading(tid: number)
	local roster = TeamService.AssignTeams(Local.GetEligiblePlayers())

	_matchParticipants = {}
	for _, teamName in TEAM_NAMES do
		for _, player in roster[teamName] do
			table.insert(_matchParticipants, player)
			RewardService.RoundEvents.OnParticipantJoined:Fire(player)
		end
	end

	if _stateId ~= tid then return end

	local activeMap = MapService.Load()
	if _stateId ~= tid then return end

	if not activeMap then
		warn("[RoundStateService] Map load failed — returning to Intermission")
		Shared.SetState("Intermission")
		return
	end

	if _stateId ~= tid then return end
	Shared.SetState("Starting")
end

function Local.HandleStarting(tid: number)
	for _, player in _matchParticipants do
		if _stateId ~= tid then return end

		local teamName = TeamService.GetTeam(player)
		if teamName then
			SpawnService.SpawnPlayer(player, teamName)
		end
	end

	Local.SetBarricadeLocked(true)

	for i = STARTING_DURATION, 0, -1 do
		if _stateId ~= tid then return end
		Workspace:SetAttribute(ATTR_TIME_LEFT, i)
		task.wait(1)
	end

	if _stateId ~= tid then return end
	Local.SetBarricadeLocked(false)
	Shared.SetState("InProgress")
end

function Local.HandleInProgress(tid: number)
	_quotaTotal = 0
	table.clear(_emptyTeamCheckId)

	task.spawn(function()
		for i = ROUND_DURATION, 0, -1 do
			if _stateId ~= tid then return end
			Workspace:SetAttribute(ATTR_TIME_LEFT, i)
			task.wait(1)
		end

		if _stateId ~= tid then return end
		Local.EndRound("TSA")
	end)
end

function Local.HandleEnded(tid: number)
	for _, player in _matchParticipants do
		RewardService.RoundEvents.OnParticipantLeft:Fire(player)
	end

	if _stateId ~= tid then return end

	MapService.Cleanup()

	for _, player in _matchParticipants do
		task.spawn(function()
			if not player:IsDescendantOf(Players) then return end

			TeamService.SetNeutral(player)
			player:LoadCharacterAsync()

			if _stateId ~= tid then return end
			SpawnService.SpawnPlayerToIntermission(player)
		end)
	end

	for i = ENDED_DISPLAY_DURATION, 0, -1 do
		if _stateId ~= tid then return end
		Workspace:SetAttribute(ATTR_TIME_LEFT, i)
		task.wait(1)
	end

	if _stateId ~= tid then return end
	Shared.SetState("Waiting")
end

-- [[ Public Functions ]] --

function Shared.SetState(newState: RoundState)
	if _state == newState then return end

	_stateId += 1
	_state = newState
	local tid = _stateId

	Shared.OnStateChange:Fire(_state)
	Workspace:SetAttribute(ATTR_STATE, _state)

	if newState == "Waiting" then
		task.spawn(Local.HandleWaiting, tid)
	elseif newState == "Intermission" then
		task.spawn(Local.HandleIntermission, tid)
	elseif newState == "MapLoading" then
		task.spawn(Local.HandleMapLoading, tid)
	elseif newState == "Starting" then
		task.spawn(Local.HandleStarting, tid)
	elseif newState == "InProgress" then
		task.spawn(Local.HandleInProgress, tid)
	elseif newState == "Ended" then
		task.spawn(Local.HandleEnded, tid)
	end
end

function Shared.GetState(): RoundState
	return _state
end

function Shared.GetQuotaTotal(): number
	return _quotaTotal
end

function Shared.GetMatchParticipants(): {Player}
	return table.clone(_matchParticipants)
end

function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)
end

return Shared