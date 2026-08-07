--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)

local JailService = require(script.Parent.JailService)
local TeamService = require(script.Parent.TeamService)
local DataService = require(script.Parent.DataService)
local RagdollService = require(script.Parent.RagdollService)

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _lifecycleConnections: {RBXScriptConnection} = {}
local _characterConnections: {[Player]: {RBXScriptConnection}} = {}

local Local = {}
local Shared = {}

Local.activeSessions = {} :: { [number]: ArrestSession }
Local.lockedTargets = {} :: { [Model]: ArrestSession }

--|| Types
type ArrestSession = {
	player: Player,
	targetCharacter: Model,
	threshold: number,
	startTime: number,
	active: boolean,
}

--|| Constants
-- Tagged on both real Smuggler characters AND every crowd NPC (see NpcService.Local.SpawnNPC) — the
-- prompt has to look identical on both, or which characters show it becomes a free "who's a Smuggler"
-- detector. Only the server-side Complete check (Local.ResolveSmuggler) knows the real answer.
local ARRESTABLE_TAG = "Arrestable"
local HANDCUFFS_ITEM_NAME = "Handcuffs"

local MAX_ARREST_DISTANCE = 8
local ARREST_TIME = 0.5
local COMPLETION_TOLERANCE = 0.5
local TIMEOUT_BUFFER = 1.5
local WATCH_TICK_RATE = 0.25

local ARREST_REWARD = 15 -- Terminal Tokens for a correct arrest, matches Handcuffs' prior arrestReward

-- Flip off once the "can't arrest" investigation is done.
local DEBUG_ARREST = true

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Arrest", "Start", function(player: Player, data: { targetCharacter: Model })
		local targetCharacter = data and data.targetCharacter
		if typeof(targetCharacter) == "Instance" and targetCharacter:IsA("Model") then
			Shared.StartArrest(player, targetCharacter)
		elseif DEBUG_ARREST then
			warn(`[ArrestService][Debug] "Start" from {player.Name} — targetCharacter did not resolve to a live Model`)
		end
	end))

	table.insert(_networkConnections, Network:BindEvent("Arrest", "Complete", function(player: Player, data: { targetCharacter: Model })
		local targetCharacter = data and data.targetCharacter
		if typeof(targetCharacter) == "Instance" and targetCharacter:IsA("Model") then
			Shared.CompleteArrest(player, targetCharacter)
		elseif DEBUG_ARREST then
			warn(`[ArrestService][Debug] "Complete" from {player.Name} — targetCharacter did not resolve to a live Model`)
		end
	end))

	table.insert(_lifecycleConnections, JailService.OnJailed:Connect(function(player: Player)
		Shared.CancelArrest(player, "Jailed")
		if player.Character then
			Local.CancelSessionsTargeting(player.Character, "TargetJailed")
		end
		Local.RefreshTag(player)
	end))

	table.insert(_lifecycleConnections, JailService.OnReleased:Connect(function(player: Player)
		Local.RefreshTag(player)
	end))

	table.insert(_lifecycleConnections, RagdollService.OnPlayerRagdolled:Connect(function(player: Player)
		Shared.CancelArrest(player, "Ragdolled")
	end))

	table.insert(_lifecycleConnections, Players.PlayerAdded:Connect(Local.WatchPlayer))
	table.insert(_lifecycleConnections, Players.PlayerRemoving:Connect(function(player: Player)
		Shared.CancelArrest(player, "Disconnected")
		if player.Character then
			Local.CancelSessionsTargeting(player.Character, "TargetDisconnected")
		end
		Local.StopWatchingPlayer(player)
	end))

	for _, player in Players:GetPlayers() do
		Local.WatchPlayer(player)
	end
end

function Shared.Start()

end

-- [[ Private Functions — Arrestable tag lifecycle (Smuggler players only; NPCs are tagged unconditionally at spawn) ]] --
function Local.WatchPlayer(player: Player)
	local connections: {RBXScriptConnection} = {}
	_characterConnections[player] = connections

	table.insert(connections, player:GetPropertyChangedSignal("Team"):Connect(function()
		Local.RefreshTag(player)
	end))

	table.insert(connections, player.CharacterAdded:Connect(function()
		Local.RefreshTag(player)
	end))

	table.insert(connections, player.CharacterRemoving:Connect(function(character: Model)
		CollectionService:RemoveTag(character, ARRESTABLE_TAG)
		Local.CancelSessionsTargeting(character, "TargetLost")
	end))

	Local.RefreshTag(player)
end

function Local.StopWatchingPlayer(player: Player)
	local connections = _characterConnections[player]
	if not connections then return end

	for _, conn in connections do
		conn:Disconnect()
	end
	_characterConnections[player] = nil
end

function Local.RefreshTag(player: Player)
	local character = player.Character
	if not character then return end

	local shouldBeArrestable = TeamService.GetTeam(player) == "Smuggler" and not JailService.IsJailed(player)

	if shouldBeArrestable then
		CollectionService:AddTag(character, ARRESTABLE_TAG)
	else
		CollectionService:RemoveTag(character, ARRESTABLE_TAG)
		Local.CancelSessionsTargeting(character, "TargetLost")
	end
end

-- [[ Private Functions — Arrest sessions ]] --
function Local.GetDistance(player: Player, targetCharacter: Model): number?
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local targetHrp = targetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?

	if not hrp or not targetHrp then return nil end

	return (hrp.Position - targetHrp.Position).Magnitude
end

function Local.IsHoldingHandcuffs(player: Player): boolean
	local character = player.Character
	return character ~= nil and character:GetAttribute("HeldItem") == HANDCUFFS_ITEM_NAME
end

-- Returns the real target Player only if they're an actual, currently-arrestable Smuggler — nil for
-- an NPC decoy (or anything else that slipped through with the Arrestable tag).
function Local.ResolveSmuggler(targetCharacter: Model): Player?
	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	if not targetPlayer then return nil end
	if TeamService.GetTeam(targetPlayer) ~= "Smuggler" then return nil end
	if JailService.IsJailed(targetPlayer) then return nil end
	return targetPlayer
end

function Local.EndSession(session: ArrestSession)
	session.active = false
	Local.lockedTargets[session.targetCharacter] = nil

	if Local.activeSessions[session.player.UserId] == session then
		Local.activeSessions[session.player.UserId] = nil
	end
end

function Local.CancelSessionsTargeting(targetCharacter: Model, reason: string)
	local session = Local.lockedTargets[targetCharacter]
	if session then
		Local.TriggerFailure(session, reason)
	end
end

function Local.PlayClinkSound(targetPlayer: Player)
	local handcuffsConfig = ItemsConfig.GetItem(HANDCUFFS_ITEM_NAME)
	local clinkSoundId = handcuffsConfig and handcuffsConfig.properties.clinkSoundId
	if not clinkSoundId or clinkSoundId == 0 then return end

	local hrp = targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local sound = Instance.new("Sound")
	sound.SoundId = `rbxassetid://{clinkSoundId}`
	sound.Volume = 1
	sound.Parent = hrp
	sound:Play()
	game.Debris:AddItem(sound, (sound.TimeLength > 0 and sound.TimeLength or 1) + 0.5)
end

function Local.TriggerSuccess(session: ArrestSession, targetPlayer: Player)
	Local.EndSession(session)

	Local.PlayClinkSound(targetPlayer)
	JailService.JailPlayer(targetPlayer, "Arrested")

	DataService.UpdateData(session.player, { type = "AddCoins", data = { amount = ARREST_REWARD } })
	DataService.UpdateData(session.player, { type = "UpdateProfile", data = { key = "totalArrests", amount = 1 } })

	Network:FireClient("Arrest", session.player, "Result", { result = "Success" })
end

-- Held the full duration on a valid-looking target, but it wasn't actually a Smuggler (an NPC decoy,
-- or a Smuggler that got jailed/left mid-hold) — strikes the TSA player via JailService's existing
-- Strike system (3 strikes jails them) instead of a silent no-op, so blind spam-cuffing has a cost.
function Local.TriggerFalseArrest(session: ArrestSession)
	Local.EndSession(session)

	JailService.JailPlayer(session.player, "Strike")
	Network:FireClient("Arrest", session.player, "Result", { result = "Failure", reason = "FalseArrest" })
end

function Local.TriggerFailure(session: ArrestSession, reason: string)
	Local.EndSession(session)

	Network:FireClient("Arrest", session.player, "Result", { result = "Failure", reason = reason })
end

function Local.RunSessionWatch(session: ArrestSession)
	local deadline = session.startTime + session.threshold + TIMEOUT_BUFFER

	while session.active do
		task.wait(WATCH_TICK_RATE)
		if not session.active then return end

		local player, targetCharacter = session.player, session.targetCharacter

		if not player.Parent or not targetCharacter.Parent then
			Local.TriggerFailure(session, "TargetLost")
			return
		end

		if TeamService.GetTeam(player) ~= "TSA" or JailService.IsJailed(player) or not Local.IsHoldingHandcuffs(player) then
			Local.TriggerFailure(session, "Invalid")
			return
		end

		local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
		if targetPlayer and JailService.IsJailed(targetPlayer) then
			Local.TriggerFailure(session, "TargetJailed")
			return
		end

		local distance = Local.GetDistance(player, targetCharacter)
		if not distance then
			Local.TriggerFailure(session, "Invalid")
			return
		end

		if distance > MAX_ARREST_DISTANCE then
			Local.TriggerFailure(session, "OutOfRange")
			return
		end

		if workspace:GetServerTimeNow() >= deadline then
			Local.TriggerFailure(session, "Timeout")
			return
		end
	end
end

-- [[ Public Functions ]] --
function Shared.StartArrest(player: Player, targetCharacter: Model): boolean
	if player.Character == targetCharacter then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] StartArrest({player.Name}) — rejected: cannot arrest self`) end
		return false
	end

	if TeamService.GetTeam(player) ~= "TSA" then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] StartArrest({player.Name}, {targetCharacter.Name}) — rejected: player is not TSA`) end
		return false
	end

	if JailService.IsJailed(player) then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] StartArrest({player.Name}, {targetCharacter.Name}) — rejected: player is jailed`) end
		return false
	end

	if not Local.IsHoldingHandcuffs(player) then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] StartArrest({player.Name}, {targetCharacter.Name}) — rejected: player is not holding Handcuffs`) end
		return false
	end

	if not targetCharacter.Parent or not CollectionService:HasTag(targetCharacter, ARRESTABLE_TAG) then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] StartArrest({player.Name}, {targetCharacter.Name}) — rejected: target is not Arrestable`) end
		return false
	end

	if Local.activeSessions[player.UserId] then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] StartArrest({player.Name}, {targetCharacter.Name}) — rejected: player already has an active arrest session`) end
		return false
	end

	if Local.lockedTargets[targetCharacter] then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] StartArrest({player.Name}, {targetCharacter.Name}) — rejected: target already locked by another arrest session`) end
		return false
	end

	local distance = Local.GetDistance(player, targetCharacter)
	if not distance or distance > MAX_ARREST_DISTANCE then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] StartArrest({player.Name}, {targetCharacter.Name}) — rejected: distance {distance} exceeds {MAX_ARREST_DISTANCE}`) end
		return false
	end

	local session: ArrestSession = {
		player = player,
		targetCharacter = targetCharacter,
		threshold = ARREST_TIME,
		startTime = workspace:GetServerTimeNow(),
		active = true,
	}

	Local.activeSessions[player.UserId] = session
	Local.lockedTargets[targetCharacter] = session

	if DEBUG_ARREST then
		print(`[ArrestService][Debug] StartArrest({player.Name}, {targetCharacter.Name}) — session started, threshold={ARREST_TIME}`)
	end

	task.spawn(Local.RunSessionWatch, session)

	return true
end

function Shared.CompleteArrest(player: Player, targetCharacter: Model): boolean
	local session = Local.activeSessions[player.UserId]
	if not session or not session.active then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] CompleteArrest({player.Name}, {targetCharacter.Name}) — rejected: no active session`) end
		return false
	end
	if session.targetCharacter ~= targetCharacter then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] CompleteArrest({player.Name}, {targetCharacter.Name}) — rejected: session target mismatch (session target={session.targetCharacter.Name})`) end
		return false
	end

	local elapsed = workspace:GetServerTimeNow() - session.startTime
	if elapsed + COMPLETION_TOLERANCE < session.threshold then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] CompleteArrest({player.Name}, {targetCharacter.Name}) — rejected: elapsed {elapsed} < threshold {session.threshold}`) end
		return false
	end

	local distance = Local.GetDistance(player, targetCharacter)
	if not distance or distance > MAX_ARREST_DISTANCE then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] CompleteArrest({player.Name}, {targetCharacter.Name}) — rejected: out of range ({distance})`) end
		Local.TriggerFailure(session, "OutOfRange")
		return false
	end

	local targetPlayer = Local.ResolveSmuggler(targetCharacter)
	if not targetPlayer then
		if DEBUG_ARREST then warn(`[ArrestService][Debug] CompleteArrest({player.Name}, {targetCharacter.Name}) — FALSE ARREST (not a live Smuggler)`) end
		Local.TriggerFalseArrest(session)
		return true
	end

	if DEBUG_ARREST then
		print(`[ArrestService][Debug] CompleteArrest({player.Name}, {targetCharacter.Name}) — SUCCESS`)
	end

	Local.TriggerSuccess(session, targetPlayer)
	return true
end

function Shared.CancelArrest(player: Player, reason: string?)
	local session = Local.activeSessions[player.UserId]
	if not session then return end

	Local.TriggerFailure(session, reason or "Cancelled")
end

function Shared.GetActiveSession(player: Player): ArrestSession?
	return Local.activeSessions[player.UserId]
end

function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	for _, conn in _lifecycleConnections do
		conn:Disconnect()
	end
	table.clear(_lifecycleConnections)

	for _, connections in _characterConnections do
		for _, conn in connections do
			conn:Disconnect()
		end
	end
	table.clear(_characterConnections)

	table.clear(Local.activeSessions)
	table.clear(Local.lockedTargets)
end

return Shared
