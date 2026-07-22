--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

local SpawnService = require(script.Parent.SpawnService)
local TeamService = require(script.Parent.TeamService)

--|| Types
type JailRecord = {
	offenseCount: number,
	strikeCount: number,
	jailThread: thread?,
	isJailed: boolean
}

--|| Variables
local _jailRecords: {[number]: JailRecord} = {} -- [userId] = JailRecord
local _connections: {RBXScriptConnection} = {}

--|| Constants
local JAIL_DURATIONS = {
	[1] = 15,  -- 1st offense
	[2] = 25,  -- 2nd offense
	[3] = 40,  -- 3rd offense
	[4] = 60,  -- 4th+ offense (cap)
}

local TSA_MAX_STRIKES = 3

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Signals ]] --
Shared.OnJailed = ModuleUtils.signal.new() :: typeof(ModuleUtils.signal.new())

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, Players.PlayerAdded:Connect(function(player: Player)
		Local.InitRecord(player)
	end))

	table.insert(_connections, Players.PlayerRemoving:Connect(function(player: Player)
		Local.CleanupRecord(player)
	end))

	for _, player in Players:GetPlayers() do
		Local.InitRecord(player)
	end
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.InitRecord(player: Player)
	_jailRecords[player.UserId] = {
		offenseCount = 0,
		strikeCount = 0,
		jailThread = nil,
		isJailed = false
	}
end

function Local.CleanupRecord(player: Player)
	local record = _jailRecords[player.UserId]
	if record and record.jailThread then
		task.cancel(record.jailThread)
	end
	_jailRecords[player.UserId] = nil
end

function Local.GetJailDuration(player: Player): number
	local record = Shared.GetRecord(player)
	if not record then return JAIL_DURATIONS[1] end

	local offense = record.offenseCount
	local maxTier = #JAIL_DURATIONS
	return JAIL_DURATIONS[math.min(offense, maxTier)]
end

function Local.GetJailModel(): Model?
	local tagged = CollectionService:GetTagged("Jail")
	if #tagged == 0 then
		warn("[JailService] No model tagged 'Jail' found in workspace")
		return nil
	end
	return tagged[1] :: Model
end

function Local.TeleportToJail(player: Player)
	local character = player.Character
	if not character then return end

	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not humanoid or not hrp then return end

	local jailModel = Local.GetJailModel()
	if not jailModel then return end

	-- Use model pivot as center, adjust Y so feet touch floor
	local pivotCFrame = jailModel:GetPivot()
	local modelSize = jailModel:GetExtentsSize()
	local floorY = pivotCFrame.Position.Y - (modelSize.Y / 2)
	local spawnY = floorY + humanoid.HipHeight + (hrp.Size.Y / 2)

	local jailCFrame = CFrame.new(Vector3.new(pivotCFrame.Position.X, spawnY, pivotCFrame.Position.Z))
	character:PivotTo(jailCFrame)

	-- Lock movement on client
	Network:FireClient("Jail", player, "LockMovement", {})
end

function Local.RunJailCountdown(player: Player, duration: number)
	local record = Shared.GetRecord(player)
	if not record then return end

	record.jailThread = task.delay(duration, function()
		if not _jailRecords[player.UserId] then return end -- Player left mid-sentence

		record.isJailed = false
		record.jailThread = nil

		-- Unlock movement before respawning
		Network:FireClient("Jail", player, "UnlockMovement", {})

		local teamName = TeamService.GetTeam(player)
		if teamName then
			SpawnService.SpawnPlayer(player, teamName)
		end

		Network:FireClient("Jail", player, "Released", { teamName = teamName or "" })
	end)
end

-- [[ Public Functions ]] --
function Shared.GetRecord(player: Player): JailRecord?
	return _jailRecords[player.UserId]
end

function Shared.JailPlayer(player: Player, reason: "Arrested" | "FalseArrest" | "Strike")
	local record = Shared.GetRecord(player)
	if not record then return end

	-- Cancel any existing jail thread (re-arrest resets the timer)
	if record.jailThread then
		task.cancel(record.jailThread)
		record.jailThread = nil
	end

	if reason == "Strike" then
		-- TSA strike handling
		record.strikeCount += 1

		if record.strikeCount < TSA_MAX_STRIKES then
			-- Not jailed yet, just notify
			Network:FireClient("Jail", player, "Strike", { strikeCount = record.strikeCount, maxStrikes = TSA_MAX_STRIKES })
			return
		end

		-- Hit max strikes — jail the TSA agent and reset strikes
		record.strikeCount = 0
		record.offenseCount += 1
	else
		record.offenseCount += 1
	end

	record.isJailed = true
	Shared.OnJailed:Fire(player)

	local duration = Local.GetJailDuration(player)

	Local.TeleportToJail(player)

	Network:FireClient("Jail", player, "Sentenced", {
		duration = duration,
		reason = reason,
		offenseCount = record.offenseCount
	})

	Local.RunJailCountdown(player, duration)
end

function Shared.ReleasePlayer(player: Player)
	local record = Shared.GetRecord(player)
	if not record or not record.isJailed then return end

	if record.jailThread then
		task.cancel(record.jailThread)
		record.jailThread = nil
	end

	record.isJailed = false

	-- Unlock movement before respawning
	Network:FireClient("Jail", player, "UnlockMovement", {})

	local teamName = TeamService.GetTeam(player)
	if teamName then
		SpawnService.SpawnPlayer(player, teamName)
	end

	Network:FireClient("Jail", player, "Released", { teamName = teamName or "" })
end

function Shared.IsJailed(player: Player): boolean
	local record = Shared.GetRecord(player)
	return record ~= nil and record.isJailed
end

function Shared.GetStrikeCount(player: Player): number
	local record = Shared.GetRecord(player)
	return record and record.strikeCount or 0
end

function Shared.ResetMatch()
	for userId, record in _jailRecords do
		if record.jailThread then
			task.cancel(record.jailThread)
		end
		record.offenseCount = 0
		record.strikeCount = 0
		record.jailThread = nil
		record.isJailed = false
	end
end

return Shared