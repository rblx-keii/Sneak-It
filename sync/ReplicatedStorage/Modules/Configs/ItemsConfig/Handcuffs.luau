--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local JailService = RunService:IsServer() and require(ServerScriptService.Services.JailService) or nil
local TeamService = RunService:IsServer() and require(ServerScriptService.Services.TeamService) or nil
local DataService = RunService:IsServer() and require(ServerScriptService.Services.DataService) or nil

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

--|| Constants
local EVENT_NAME = `Item_{script.Name}`
local COOLDOWN_ATTR = "LastUse"
local AWAITING_HIT_ATTR = "AwaitingHandcuffHit"

--|| Item ||--
local item = {}

item.properties = {
	iconId = 123308856629534,
	cooldown = 1,
	range = 15, -- short — this is a wand-check, not a projectile
	validationThreshold = 4,
	clinkSoundId = 0, -- fill in — handcuffs click sound
	idleAnimationId = 0, -- fill in
	useAnimationId = 0, -- fill in — optional quick "cuff" animation
	arrestReward = 15, -- Terminal Tokens for a correct arrest, matches ArrestService
}

item.attributes = {
	Rating = 1,
	Weight = 0.5,
	IsContraband = true,
}

item.usable = true

--|| Client-only animation state ||--
local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil
local _useTrack: AnimationTrack? = nil

--|| Private Functions ||--

local function IsOnCooldown(itemModel: Model): boolean
	local lastUse = itemModel:GetAttribute(COOLDOWN_ATTR) or 0
	local now = Workspace:GetServerTimeNow()
	return (now - lastUse) < item.properties.cooldown
end

local function StampCooldown(itemModel: Model)
	itemModel:SetAttribute(COOLDOWN_ATTR, Workspace:GetServerTimeNow())
end

if item.usable then
	-- CALLING CONVENTION: item.Use(player, consume, originCFrame, direction)
	item.Use = function(player_: Player, _consume: (() -> ())?, originCFrame: CFrame?, direction: Vector3?)
		if RunService:IsServer() then
			-- [[ SERVER ]] --
			local character = player_.Character
			if not character then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel then return end

			if IsOnCooldown(itemModel) then return end

			local uid = itemModel:GetAttribute("UID")
			if not uid then return end

			local awaitingKey = `{AWAITING_HIT_ATTR}_{uid}`
			character:SetAttribute(awaitingKey, true)
			task.delay(1, function()
				if character and character.Parent then
					character:SetAttribute(awaitingKey, false)
				end
			end)
		else
			-- [[ CLIENT ]] --
			if not originCFrame or not direction then return end

			local character = player_.Character
			if not character then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel then return end

			if IsOnCooldown(itemModel) then return end

			item.PlayUseAnimation()

			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.FilterDescendantsInstances = { character }

			local result = Workspace:Raycast(originCFrame.Position, direction.Unit * item.properties.range, rayParams)
			if not result then return end

			local hitCharacter = result.Instance:FindFirstAncestorWhichIsA("Model")
			local hitHasHumanoid = hitCharacter and hitCharacter:IsA("Model")
				and hitCharacter:FindFirstChildOfClass("Humanoid") ~= nil

			local uid = itemModel:GetAttribute("UID")

			Network:FireServer(EVENT_NAME, "ReportHit", {
				uid = uid,
				hitPosition = result.Position,
				hitInstance = hitHasHumanoid and result.Instance or nil,
			})
		end
	end
end

-- [[ Server-side hit validation + arrest ]] --
function item.ValidateHit(tsaPlayer: Player, data: { uid: string?, hitPosition: Vector3, hitInstance: Instance? })
	local character = tsaPlayer.Character
	if not character then return end
	if not data.uid then return end

	local awaitingKey = `{AWAITING_HIT_ATTR}_{data.uid}`
	if not character:GetAttribute(awaitingKey) then return end
	character:SetAttribute(awaitingKey, false)

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	if not data.hitInstance then return end
	if (hrp.Position - data.hitPosition).Magnitude > item.properties.range + item.properties.validationThreshold then return end

	local hitCharacter = data.hitInstance:FindFirstAncestorWhichIsA("Model")
	if not hitCharacter or not hitCharacter:IsA("Model") then return end

	local targetPlayer = Players:GetPlayerFromCharacter(hitCharacter)
	if not targetPlayer then return end

	-- TSA-only tool: bail if the user isn't TSA or the target isn't a Smuggler.
	if TeamService.GetTeam(tsaPlayer) ~= "TSA" then return end
	if TeamService.GetTeam(targetPlayer) ~= "Smuggler" then return end

	if JailService.IsJailed(targetPlayer) then return end

	if item.properties.clinkSoundId ~= 0 then
		local sound = Instance.new("Sound")
		sound.SoundId = `rbxassetid://{item.properties.clinkSoundId}`
		sound.Volume = 1
		sound.Parent = data.hitInstance
		sound:Play()
		game.Debris:AddItem(sound, (sound.TimeLength > 0 and sound.TimeLength or 1) + 0.5)
	end

	JailService.JailPlayer(targetPlayer, "Arrested")

	DataService.UpdateData(tsaPlayer, { type = "AddCoins", data = { amount = item.properties.arrestReward } })
	DataService.UpdateData(tsaPlayer, { type = "UpdateProfile", data = { key = "totalArrests", amount = 1 } })
end

--|| Initialize ||--

function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then

		Network:BindEvent(EVENT_NAME, "ReportHit", function(sender: Player, data: any)
			local character = sender.Character
			if not character then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel then return end
			if IsOnCooldown(itemModel) then return end

			local record = JailService.GetRecord(sender)
			if not record or record.isJailed then return end

			StampCooldown(itemModel)
			item.ValidateHit(sender, data)
		end)
	else
		Network:BindEvent(EVENT_NAME, "ForceUnequip", function(itemName: string)
			if itemName ~= script.Name then return end
			item.OnUnequip(player and player.Character and player.Character:FindFirstChild(itemName))
		end)
	end

	_initialized = true
end

--|| Animations ||--

function item.OnEquip(_itemModel: Instance?)
	if RunService:IsServer() then return end
	if not player or not player.Character then return end

	local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end

	_currentAnimator = animator

	local handleMotor = _itemModel and _itemModel:WaitForChild("Handle_Motor", 5)
	if not handleMotor then return end

	if item.properties.idleAnimationId == 0 then return end

	local idleAnim = Instance.new("Animation")
	idleAnim.AnimationId = `rbxassetid://{item.properties.idleAnimationId}`

	_idleTrack = animator:LoadAnimation(idleAnim)
	_idleTrack.Priority = Enum.AnimationPriority.Movement
	_idleTrack.Looped = true
	_idleTrack:Play(0.15)
end

function item.OnUnequip(_itemModel: Instance?)
	if RunService:IsServer() then return end

	if _idleTrack then
		_idleTrack:Stop(0.15)
		_idleTrack:Destroy()
		_idleTrack = nil
	end

	if _useTrack then
		_useTrack:Stop(0)
		_useTrack:Destroy()
		_useTrack = nil
	end

	_currentAnimator = nil
end

function item.PlayUseAnimation()
	if RunService:IsServer() then return end
	if not _currentAnimator then return end

	if _useTrack then
		_useTrack:Stop(0)
		_useTrack:Destroy()
	end

	if item.properties.useAnimationId == 0 then
		_useTrack = nil
		return
	end

	local useAnim = Instance.new("Animation")
	useAnim.AnimationId = `rbxassetid://{item.properties.useAnimationId}`

	_useTrack = _currentAnimator:LoadAnimation(useAnim)
	_useTrack.Priority = Enum.AnimationPriority.Action
	_useTrack.Looped = false
	_useTrack:Play(0.05)
end

item.OnInitialize()

return item
