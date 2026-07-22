--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

local _pendingAction: { [Player]: { uid: string, resolve: (() -> ())? } } = {}
local PENDING_ACTION_TIMEOUT = 30

local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil
local _useTrack: AnimationTrack? = nil

--|| Constants
local EVENT_NAME = `Item_{script.Name}`
local COOLDOWN_ATTR = "LastHonk"
local SUPPRESS_AUDIO_ATTR = "SuppressAudioCues"

--|| Item ||--
local item = {}

item.properties = {
	cooldown = 20, -- high cooldown, reusable
	requiresAim = false, -- self-centered area effect, no aim needed

	radius = 25,
	suppressDuration = 5, -- seconds SuppressAudioCues stays true on affected characters
	hornSoundId = "rbxassetid://132844961288199",
	hornSoundRolloff = 100, -- studs — loud enough to be heard well beyond `radius`

	idleAnimationId = 126911093537034,
	useAnimationId = 123999618262206,

	spawnWeight = 50, -- relative chance to spawn where this item is scattered (higher = more common)
	itemType = "Chaos", -- item-spawn category (ItemSpawnService); "Chaos" | "Non-functional"
}

item.attributes = {
	Rating = 1.5,
	Weight = 1.0,
	MaxWeight = nil,
	IsBag = false,
}

item.usable = true

--|| Private Functions ||--

local function IsOnCooldown(itemModel: Model): boolean
	local lastHonk = itemModel:GetAttribute(COOLDOWN_ATTR) or 0
	local now = Workspace:GetServerTimeNow()
	return (now - lastHonk) < item.properties.cooldown
end

local function StampCooldown(itemModel: Model)
	itemModel:SetAttribute(COOLDOWN_ATTR, Workspace:GetServerTimeNow())
end

local function GetHeldItemModel(character: Model): Model?
	local heldItemName = character:GetAttribute("HeldItem")
	return heldItemName and character:FindFirstChild(heldItemName) :: Model?
end

-- [[ Item-Specific Effect (SERVER, authoritative) ]] --
-- Entirely server-resolved — this isn't testing aim/reflexes, just "who's
-- near me right now," which the server already knows authoritatively.
function item._ExecuteEffect(player_: Player, _itemModel: Model, _actionData: { [string]: any }?)
	local character = player_.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local sound = Instance.new("Sound")
	sound.SoundId = item.properties.hornSoundId
	sound.Volume = 1
	sound.RollOffMaxDistance = item.properties.hornSoundRolloff
	sound.Parent = hrp
	sound:Play()
	game.Debris:AddItem(sound, (sound.TimeLength > 0 and sound.TimeLength or 2) + 0.5)

	local boxSize = Vector3.new(item.properties.radius * 2, item.properties.radius * 2, item.properties.radius * 2)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }

	local parts = Workspace:GetPartBoundsInBox(hrp.CFrame, boxSize, overlapParams)

	local affected: { [Model]: boolean } = {}

	for _, part in parts do
		local otherCharacter = part:FindFirstAncestorWhichIsA("Model")
		if not otherCharacter or otherCharacter == character or affected[otherCharacter] then continue end
		if not otherCharacter:FindFirstChildOfClass("Humanoid") then continue end

		affected[otherCharacter] = true
		otherCharacter:SetAttribute(SUPPRESS_AUDIO_ATTR, true)

		task.delay(item.properties.suppressDuration, function()
			if otherCharacter and otherCharacter.Parent then
				otherCharacter:SetAttribute(SUPPRESS_AUDIO_ATTR, false)
			end
		end)
	end
end

-- [[ Use Flow ]] --
if item.usable then
	-- CALLING CONVENTION: item.Use(player, consume, originCFrame, direction)
	item.Use = function(player_: Player, _consume: (() -> ())?, _originCFrame: CFrame?, _direction: Vector3?)
		if RunService:IsServer() then
			return
		else
			-- [[ CLIENT ]] --
			local character = player_.Character
			if not character then return end

			local itemModel = GetHeldItemModel(character)
			if not itemModel then return end

			if IsOnCooldown(itemModel) then return end

			item.PlayUseAnimation()

			local track = item._useTrack
			if not track then
				local uid = itemModel:GetAttribute("UID")
				Network:FireServer(EVENT_NAME, "UseItem", { uid = uid })
				return
			end

			local markerConnection: RBXScriptConnection? = nil
			markerConnection = track:GetMarkerReachedSignal("SoundHorn"):Connect(function()
				if markerConnection then
					markerConnection:Disconnect()
					markerConnection = nil
				end

				local currentItemModel = GetHeldItemModel(character)
				if not currentItemModel then return end

				local uid = currentItemModel:GetAttribute("UID")
				Network:FireServer(EVENT_NAME, "UseItem", { uid = uid })
			end)

			track.Stopped:Once(function()
				if markerConnection then
					markerConnection:Disconnect()
					markerConnection = nil
				end
			end)
		end
	end
end

--|| Initialize ||--
function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then
		-- [[ Hand-equip rig: generic to every held item ]] --
		local _lastItemGripWeld: WeldConstraint? = nil

		Network:BindEvent(EVENT_NAME, "Equip", function(_playerOwner: Player, _itemModel: Instance?)
			if not _itemModel then return end

			local weldFolder = _itemModel:FindFirstChild("ItemWelds")
			if not weldFolder then return end

			local gripWeld: WeldConstraint? = nil
			for _, weld in weldFolder:GetChildren() do
				if weld.Name:lower():find("grip") and weld:IsA("WeldConstraint") then
					gripWeld = weld
					break
				end
			end

			if not gripWeld then return end

			local motor = Instance.new("Motor6D")
			motor.Name = "Handle_Motor"
			motor.Part0 = gripWeld.Part0
			motor.Part1 = gripWeld.Part1
			motor.Parent = _itemModel

			gripWeld.Parent = ReplicatedStorage.Debris
			_lastItemGripWeld = gripWeld
		end)

		Network:BindEvent(EVENT_NAME, "Unequip", function(_playerOwner: Player, _itemModel: Instance?)
			if _itemModel then
				local handleMotor = _itemModel:FindFirstChild("Handle_Motor")
				if handleMotor then
					handleMotor:Destroy()
				end

				if _lastItemGripWeld then
					_lastItemGripWeld.Part0 = nil
					_lastItemGripWeld.Parent = _itemModel:FindFirstChild("ItemWelds") or _itemModel
				end
			else
				if _lastItemGripWeld then
					_lastItemGripWeld:Destroy()
				end
			end
			_lastItemGripWeld = nil
		end)

		-- [[ Generic "UseItem" resolution for the "Sound Horn" marker confirm ]] --
		Network:BindEvent(EVENT_NAME, "UseItem", function(sender: Player, data: { uid: string? })
			local character = sender.Character
			if not character then return end
			if not data.uid then return end

			local itemModel = GetHeldItemModel(character)
			if not itemModel or itemModel:GetAttribute("UID") ~= data.uid then return end
			if IsOnCooldown(itemModel) then return end
			StampCooldown(itemModel)

			item._ExecuteEffect(sender, itemModel, nil)
		end)

		Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
			_pendingAction[leavingPlayer] = nil
		end)
	elseif RunService:IsClient() then
		Network:BindEvent(EVENT_NAME, "ForceUnequip", function(itemName: string)
			if itemName ~= script.Name then return end
			item.OnUnequip(player and player.Character and player.Character:FindFirstChild(itemName))
		end)
	end

	_initialized = true
end

--|| Animations ||--

local function GetOrFetchAnimator(): Animator?
	if _currentAnimator then return _currentAnimator end
	if not player or not player.Character then return nil end

	local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
	_currentAnimator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	return _currentAnimator
end

function item.OnEquip(_itemModel: Instance?)
	if RunService:IsServer() then return end
	if not player or not player.Character then return end

	local animator = GetOrFetchAnimator()
	if not animator then return end

	Network:FireServer(EVENT_NAME, "Equip", _itemModel)

	local handleMotor = _itemModel and _itemModel:WaitForChild("Handle_Motor", 5)
	if not handleMotor then return end

	local idleAnim = Instance.new("Animation")
	idleAnim.AnimationId = `rbxassetid://{item.properties.idleAnimationId}`

	_idleTrack = animator:LoadAnimation(idleAnim)
	_idleTrack.Priority = Enum.AnimationPriority.Idle
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

	if item._useTrack then
		item._useTrack:Stop(0)
		item._useTrack:Destroy()
		item._useTrack = nil
	end

	Network:FireServer(EVENT_NAME, "Unequip", _itemModel)

	_currentAnimator = nil
end

function item.PlayUseAnimation()
	if RunService:IsServer() then return end

	local animator = GetOrFetchAnimator()
	if not animator then return end

	if item._useTrack then
		item._useTrack:Stop(0)
		item._useTrack:Destroy()
	end

	if item.properties.useAnimationId == 0 then
		item._useTrack = nil
		return
	end

	local useAnim = Instance.new("Animation")
	useAnim.AnimationId = `rbxassetid://{item.properties.useAnimationId}`

	item._useTrack = animator:LoadAnimation(useAnim)
	item._useTrack.Priority = Enum.AnimationPriority.Action
	item._useTrack.Looped = false
	item._useTrack:Play(0.05)
end

item.OnInitialize()

return item