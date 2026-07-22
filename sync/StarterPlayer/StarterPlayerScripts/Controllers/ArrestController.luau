--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)

local ProximityPrompt = require(ReplicatedStorage.Modules.Shared.Classes.ProximityPrompt)

local player = Players.LocalPlayer

--|| Variables
local _activePrompts: { [Model]: ProximityPrompt.ClassType } = {}
local _npcPrompts: { [Model]: ProximityPrompt.ClassType } = {}
local _knownNPCs: { [Model]: boolean } = {}

local _localTeam: any = ""

--|| Constants
local PROMPT_DURATION_ARREST = 0.5
local MAX_INTERACT_DISTANCE = 10

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Observers.observeProperty(player, "Team", function(teamValue)
		_localTeam = teamValue or ""
		Local.RefreshAllPrompts()
		Local.RefreshAllNPCPrompts()
	end)

	Local.WatchNPCs()

	Observers.observePlayer(function(otherPlayer: Player)
		if otherPlayer == player then
			return
		end

		local stopTeam = Observers.observeProperty(otherPlayer, "Team", function(_teamValue)
			Local.RefreshPromptForPlayer(otherPlayer)
		end)

		local stopChar = Observers.observeCharacter(function(_, character: Model)
			Local.RefreshPromptForPlayer(otherPlayer)

			return function()
				Local.RemovePrompt(character)
			end
		end)

		return function()
			stopTeam()
			stopChar()
			if otherPlayer.Character then
				Local.RemovePrompt(otherPlayer.Character)
			end
		end
	end)
end

function Shared.Start() end

-- [[ Private Functions ]] --
function Local.RefreshAllPrompts()
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= player then
			Local.RefreshPromptForPlayer(otherPlayer)
		end
	end
end

function Local.RefreshPromptForPlayer(targetPlayer: Player)
	local character = targetPlayer.Character
	if not character then
		return
	end

	local targetTeamAttr = targetPlayer:GetAttribute("Team")
	local targetTeamProp = targetPlayer.Team

	local targetTeamStr = targetTeamAttr or (targetTeamProp and targetTeamProp.Name) or ""
	local localTeamStr = typeof(_localTeam) == "Instance" and _localTeam.Name or tostring(_localTeam)

	local isTSA = (localTeamStr == "TSA")
	local isSmuggler = (targetTeamStr == "Smuggler")

	if isTSA and isSmuggler then
		Local.EnsurePrompt(targetPlayer, character)
	else
		Local.RemovePrompt(character)
	end
end

function Local.EnsurePrompt(targetPlayer: Player, character: Model)
	if _activePrompts[character] then
		return
	end

	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not hrp then
		return
	end

	local prompt = ProximityPrompt.new({
		name = `Player_{targetPlayer.UserId}`,
		actionText = "Arrest Player",
		objectText = targetPlayer.Name,
		holdDuration = PROMPT_DURATION_ARREST,
		maxActivationDistance = MAX_INTERACT_DISTANCE,
		enabled = true,
		keyboardKeyCode = Enum.KeyCode.E,
		gamepadKeyCode = Enum.KeyCode.ButtonX,
		parent = hrp,
	})

	prompt.Triggered:Connect(function()
		Network:FireServer("Arrest", "Attempt", { targetUserId = targetPlayer.UserId })
	end)

	_activePrompts[character] = prompt
end

function Local.RemovePrompt(character: Model)
	local prompt = _activePrompts[character]
	if prompt then
		prompt:Destroy()
		_activePrompts[character] = nil
	end
end

function Local.WatchNPCs()
	-- TODO: not yet implemented — NPC arrest prompts never populate
end

function Local.RefreshAllNPCPrompts()
	for npc in _knownNPCs do
		Local.RefreshNPCPrompt(npc)
	end
end

function Local.RefreshNPCPrompt(npc: Model)
	local localTeamStr = typeof(_localTeam) == "Instance" and _localTeam.Name or tostring(_localTeam)

	if localTeamStr == "TSA" then
		Local.EnsureNPCPrompt(npc)
	else
		Local.RemoveNPCPrompt(npc)
	end
end

function Local.EnsureNPCPrompt(npc: Model)
	if _npcPrompts[npc] then
		return
	end

	local hrp = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	local uid = npc:GetAttribute("UID")
	if not hrp or not uid then
		return
	end

	local prompt = ProximityPrompt.new({
		name = `NPC_{uid}`,
		actionText = "Arrest",
		objectText = npc.Name,
		holdDuration = PROMPT_DURATION_ARREST,
		maxActivationDistance = MAX_INTERACT_DISTANCE,
		enabled = true,
		keyboardKeyCode = Enum.KeyCode.E,
		gamepadKeyCode = Enum.KeyCode.ButtonX,
		parent = hrp,
	})

	prompt.Triggered:Connect(function()
		Network:FireServer("Arrest", "Attempt", { npcId = uid })
	end)

	_npcPrompts[npc] = prompt
end

function Local.RemoveNPCPrompt(npc: Model)
	local prompt = _npcPrompts[npc]
	if prompt then
		prompt:Destroy()
		_npcPrompts[npc] = nil
	end
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, prompt in _activePrompts do
		prompt:Destroy()
	end
	table.clear(_activePrompts)

	for _, prompt in _npcPrompts do
		prompt:Destroy()
	end
	table.clear(_npcPrompts)
	table.clear(_knownNPCs)
end

return Shared
