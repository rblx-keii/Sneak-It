--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

-- Accessory template — adjust path to wherever your assets live
local AccessoryTemplate = ReplicatedStorage.Assets.Accessories:FindFirstChild("PaddedJacket")

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
local COOLDOWN_ATTR = "LastUse"
local JACKET_ATTR = "HasJacket"

--|| Types
export type PendingAction = {
	uid: string,
	resolve: (() -> ())?,
}

--|| Item ||--
local item = {}

item.properties = {
	iconId = 134011246639736, -- item icon asset id
	cooldown = 0, -- single-use consumable, no reuse cooldown needed
	idleAnimationId = 140339485311797,
	useAnimationId = 0, -- add an equip animation id if/when one exists
	requiresAim = false, -- self-target instant effect

	accessoryName = "PaddedJacket_Accessory",
}

item.attributes = {
	Rating = 4.5,
	Weight = 5.0,
	MaxWeight = nil,
	IsBag = false,
}

item.usable = true

--|| Private Functions ||--

local function IsOnCooldown(itemModel: Model): boolean
	local lastUse = itemModel:GetAttribute(COOLDOWN_ATTR) or 0
	local now = Workspace:GetServerTimeNow()
	return (now - lastUse) < item.properties.cooldown
end

local function StampCooldown(itemModel: Model)
	itemModel:SetAttribute(COOLDOWN_ATTR, Workspace:GetServerTimeNow())
end

local function GetHeldItemModel(character: Model): Model?
	local heldItemName = character:GetAttribute("HeldItem")
	return heldItemName and character:FindFirstChild(heldItemName) :: Model?
end

-- [[ Item-Specific Effect (SERVER, authoritative) ]] --
function item._ExecuteEffect(player_: Player, _itemModel: Model, _actionData: { [string]: any }?)
	local character = player_.Character
	if not character then return end

	-- Already wearing one — don't double-equip
	if character:GetAttribute(JACKET_ATTR) then return end

	character:SetAttribute(JACKET_ATTR, true)

	if AccessoryTemplate then
		local accessory = AccessoryTemplate:Clone()
		accessory.Name = item.properties.accessoryName
		accessory.Parent = character
	else
		warn("[PaddedJacket] AccessoryTemplate not found in ReplicatedStorage.Assets.Accessories")
	end

	Network:FireClient(EVENT_NAME, player_, "JacketEquipped", {})
end

-- [[ Public Functions ]] --
-- Called by RagdollService / ArrestService BEFORE applying a ragdoll or
-- tackle effect. If the player has a jacket, it breaks (removes flag +
-- accessory) and the ragdoll/tackle is cancelled. Returns true if the hit
-- was absorbed. This sits outside the standard Use flow — it's invoked by
-- other services, not by ItemService.
function item.TryAbsorbHit(character: Model): boolean
	if not character:GetAttribute(JACKET_ATTR) then
		return false
	end

	character:SetAttribute(JACKET_ATTR, false)

	local accessory = character:FindFirstChild(item.properties.accessoryName)
	if accessory then
		accessory:Destroy()
	end

	local absorbingPlayer = Players:GetPlayerFromCharacter(character)
	if absorbingPlayer then
		Network:FireClient(EVENT_NAME, absorbingPlayer, "JacketBroken", {})
	end

	return true
end

-- [[ Use Flow ]] --
if item.usable then
	-- CALLING CONVENTION: item.Use(player, consume, originCFrame, direction)
	item.Use = function(player_: Player, consume: (() -> ())?, _originCFrame: CFrame?, _direction: Vector3?)
		if RunService:IsServer() then
			-- [[ SERVER ]] --
			local character = player_.Character
			if not character then return end

			local itemModel = GetHeldItemModel(character)
			if not itemModel then return end

			local uid = itemModel:GetAttribute("UID")
			if not uid then return end

			if IsOnCooldown(itemModel) then return end
			StampCooldown(itemModel)

			item._ExecuteEffect(player_, itemModel, nil)

			-- Jacket is consumed from inventory the moment it's worn — the
			-- "item" now lives as the HasJacket flag + accessory, not a
			-- held item.
			if consume then
				consume()
			end
		else
			-- [[ CLIENT ]] --
			-- Equip sound/animation feedback plays immediately (once
			-- useAnimationId is set); the accessory itself will replicate in
			-- from the server clone.
			item.PlayUseAnimation()
		end
	end
end

--|| Initialize ||--
function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then
		-- [[ Hand-equip rig: generic to every held item ]] --

		Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
			_pendingAction[leavingPlayer] = nil
		end)
	elseif RunService:IsClient() then
		Network:BindEvent(EVENT_NAME, "JacketEquipped", function(_data: {})
			-- Hook up equip sound/UI feedback here.
		end)

		Network:BindEvent(EVENT_NAME, "JacketBroken", function(_data: {})
			-- Hook up break sound/UI feedback here.
		end)

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

	local handleMotor = _itemModel and _itemModel:WaitForChild("Handle_Motor", 5)
	if not handleMotor then return end

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

	if item._useTrack then
		item._useTrack:Stop(0)
		item._useTrack:Destroy()
		item._useTrack = nil
	end

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