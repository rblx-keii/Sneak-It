--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local JailService = RunService:IsServer() and require(ServerScriptService.Services.JailService) or nil

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

-- SERVER: keyed by itemModel, true while that extinguisher's foam-drain loop is running.
-- Also doubles as the "is this item currently firing" idempotency guard for FireStart.
local _activeDrainLoops: { [Model]: boolean } = {}

-- CLIENT: local firing state for whichever extinguisher WE are holding.
local _isFiring = false
local _fireInputEndedConn: RBXScriptConnection? = nil

--|| Constants
local EVENT_NAME = `Item_{script.Name}`
local COOLDOWN_ATTR = "LastSpray" -- min interval between hit-detection ticks, server-enforced
local FOAM_ATTR = "FoamRemaining"
local FIRING_ATTR = "IsFiring"
local DRAIN_TICK = 0.1 -- seconds between server-side foam decrements

--|| Item ||--
local item = {}

item.properties = {
	cooldown = 0.1,
	range = 20,
	sprayWidth = 4,
	sprayHeight = 4,
	sprayImpulseForce = 60,  -- raw impulse magnitude applied to a hit target's HumanoidRootPart

	maxFoam = 1,             -- treat as a 0-1 (percentage) tank
	foamDrainPerSecond = 0.01,
	emptyWeight = 1,         -- Weight attribute value once the tank is fully drained

	idleAnimationId = 84766066701114,
	fireAnimationId = 0,     -- optional continuous fire-loop animation

	spawnWeight = 50, -- relative chance to spawn where this item is scattered (higher = more common)
	itemType = "Chaos", -- item-spawn category (ItemSpawnService); "Chaos" | "Non-functional"
}

item.attributes = {
	Rating = 4.0,
	Weight = 3.5, -- full-tank weight; drains toward properties.emptyWeight as foam depletes
}

item.usable = true

--|| Client-only animation state ||--
local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil
local _fireTrack: AnimationTrack? = nil

--|| Private Functions ||--

local function IsOnCooldown(itemModel: Model): boolean
	local lastSpray = itemModel:GetAttribute(COOLDOWN_ATTR) or 0
	local now = Workspace:GetServerTimeNow()
	return (now - lastSpray) < item.properties.cooldown
end

local function StampCooldown(itemModel: Model)
	itemModel:SetAttribute(COOLDOWN_ATTR, Workspace:GetServerTimeNow())
end

local function GetMuzzleAttachment(itemModel: Model): Attachment?
	return itemModel:FindFirstChild("MuzzleAttachment", true) :: Attachment?
end

local function GetMuzzleEmitter(itemModel: Model): ParticleEmitter?
	local muzzleAttachment = GetMuzzleAttachment(itemModel)
	return muzzleAttachment and muzzleAttachment:FindFirstChildOfClass("ParticleEmitter")
end

-- Recomputes the Weight attribute from the current foam level. ItemService
-- already reads Weight for bag-capacity checks, so this "just works" there
-- with no further changes needed on that end.
function item._UpdateWeight(itemModel: Model, foamRemaining: number)
	local ratio = math.clamp(foamRemaining / item.properties.maxFoam, 0, 1)
	local weight = item.properties.emptyWeight + (item.attributes.Weight - item.properties.emptyWeight) * ratio
	itemModel:SetAttribute("Weight", weight)
end

-- CLIENT: casts a box in front of the muzzle, oriented along the live aim
-- direction (not the stale direction captured on mouse-down), and returns
-- the deduplicated set of character Models caught in it.
local function ComputeSprayHits(muzzlePosition: Vector3, direction: Vector3, character: Model): { Model }
	local boxCFrame = CFrame.lookAt(muzzlePosition, muzzlePosition + direction) * CFrame.new(0, 0, -item.properties.range / 2)
	local boxSize = Vector3.new(item.properties.sprayWidth, item.properties.sprayHeight, item.properties.range)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }

	local parts = Workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlapParams)

	local hitCharacters: { Model } = {}
	local seen: { [Model]: boolean } = {}

	for _, part in parts do
		local hitCharacter = part:FindFirstAncestorWhichIsA("Model")
		if not hitCharacter or hitCharacter == character or seen[hitCharacter] then continue end
		if not hitCharacter:FindFirstChildOfClass("Humanoid") then continue end

		seen[hitCharacter] = true
		table.insert(hitCharacters, hitCharacter)
	end

	return hitCharacters
end

-- CLIENT: the full-auto loop kicked off once on mouse-down. Polls live
-- camera aim every tick (ItemController only calls item.Use once on Begin,
-- so this module is responsible for its own continuous aim + firing).
local function RunFireLoop(character: Model, itemModel: Model, uid: string)
	local emitter = GetMuzzleEmitter(itemModel)
	if emitter then emitter.Enabled = true end

	while _isFiring do
		if not itemModel or not itemModel.Parent then break end
		if character:GetAttribute("HeldItem") ~= itemModel.Name then break end -- unequipped/swapped mid-fire

		local foamRemaining = itemModel:GetAttribute(FOAM_ATTR)
		if foamRemaining and foamRemaining <= 0 then break end

		if not IsOnCooldown(itemModel) then
			local camera = Workspace.CurrentCamera
			if camera then
				local muzzleAttachment = GetMuzzleAttachment(itemModel)
				local muzzlePos = muzzleAttachment and muzzleAttachment.WorldPosition or camera.CFrame.Position
				local direction = camera.CFrame.LookVector

				local hitCharacters = ComputeSprayHits(muzzlePos, direction, character)

				Network:FireServer(EVENT_NAME, "ReportExtinguisherHits", {
					uid = uid,
					hitCharacters = hitCharacters,
				})
			end
		end

		task.wait(item.properties.cooldown)
	end

	_isFiring = false
	if emitter then emitter.Enabled = false end
	if _fireInputEndedConn then
		_fireInputEndedConn:Disconnect()
		_fireInputEndedConn = nil
	end
	item.StopFireAnimation()

	Network:FireServer(EVENT_NAME, "FireStop", { uid = uid })
end

if item.usable then
	-- CALLING CONVENTION: item.Use(player, consume, originCFrame, direction)
	item.Use = function(player_: Player, _consume: (() -> ())?, _originCFrame: CFrame?, _direction: Vector3?)
		if RunService:IsServer() then
			-- No-op: this is continuous full-auto, not a discrete shot, so
			-- there's nothing to validate on Use itself. All the real work
			-- happens via the FireStart/FireStop/ReportExtinguisherHits
			-- binds below, driven directly by the client's fire loop.
			return
		else
			if _isFiring then return end -- already firing, ignore re-trigger

			local character = player_.Character
			if not character then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel then return end

			local uid = itemModel:GetAttribute("UID")
			if not uid then return end

			local foamRemaining = itemModel:GetAttribute(FOAM_ATTR)
			if foamRemaining and foamRemaining <= 0 then return end

			item.PlayFireAnimation()

			_isFiring = true
			Network:FireServer(EVENT_NAME, "FireStart", { uid = uid })

			_fireInputEndedConn = UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					_isFiring = false
				end
			end)

			task.spawn(RunFireLoop, character, itemModel, uid)
		end
	end
end

--|| Initialize ||--

function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then
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
			gripWeld.Part0 = nil
			_lastItemGripWeld = gripWeld
		end)

		Network:BindEvent(EVENT_NAME, "Unequip", function(_playerOwner: Player, _itemModel: Instance?)
			if _itemModel then
				local handleMotor = _itemModel:FindFirstChild("Handle_Motor")
				if handleMotor then
					handleMotor:Destroy()
				end

				if _lastItemGripWeld then
					_lastItemGripWeld.Parent = _itemModel:FindFirstChild("ItemWelds") or _itemModel
				end
			else
				if _lastItemGripWeld then
					_lastItemGripWeld:Destroy()
				end
			end
			_lastItemGripWeld = nil

			-- Force-stop the drain loop if the tank gets unequipped mid-fire.
			if _itemModel and _activeDrainLoops[_itemModel] then
				_activeDrainLoops[_itemModel] = nil
			end
		end)

		Network:BindEvent(EVENT_NAME, "FireStart", function(sender: Player, data: { uid: string? })
			local character = sender.Character
			if not character then return end
			if not data.uid then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel or itemModel:GetAttribute("UID") ~= data.uid then return end

			local record = JailService.GetRecord(sender)
			if not record or record.isJailed then return end

			if _activeDrainLoops[itemModel] then return end -- already firing, idempotent

			local foamRemaining = itemModel:GetAttribute(FOAM_ATTR)
			if foamRemaining == nil then
				foamRemaining = item.properties.maxFoam
				itemModel:SetAttribute(FOAM_ATTR, foamRemaining)
			end
			if foamRemaining <= 0 then return end

			itemModel:SetAttribute(FIRING_ATTR, true)
			Network:FireAllExcept(EVENT_NAME, sender, "ReplicateFireStart", itemModel)

			_activeDrainLoops[itemModel] = true

			task.spawn(function()
				while _activeDrainLoops[itemModel] do
					local dt = task.wait(DRAIN_TICK)
					if not itemModel or not itemModel.Parent then break end

					local remaining = itemModel:GetAttribute(FOAM_ATTR) or 0
					remaining = math.max(0, remaining - (item.properties.foamDrainPerSecond * dt))
					itemModel:SetAttribute(FOAM_ATTR, remaining)
					item._UpdateWeight(itemModel, remaining)

					if remaining <= 0 then break end
				end

				_activeDrainLoops[itemModel] = nil
				if itemModel and itemModel.Parent then
					itemModel:SetAttribute(FIRING_ATTR, false)
				end
				Network:FireAllExcept(EVENT_NAME, sender, "ReplicateFireStop", itemModel)
			end)
		end)

		Network:BindEvent(EVENT_NAME, "FireStop", function(sender: Player, data: { uid: string? })
			local character = sender.Character
			if not character then return end
			if not data.uid then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel or itemModel:GetAttribute("UID") ~= data.uid then return end

			-- Signals the drain loop above to end on its next tick.
			_activeDrainLoops[itemModel] = nil
		end)

		Network:BindEvent(EVENT_NAME, "ReportExtinguisherHits", function(sender: Player, data: { uid: string?, hitCharacters: { Model }? })
			local character = sender.Character
			if not character then return end
			if not data.uid then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel: Model? = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel or itemModel:GetAttribute("UID") ~= data.uid then return end

			local record = JailService.GetRecord(sender)
			if not record or record.isJailed then return end

			if IsOnCooldown(itemModel) then return end
			StampCooldown(itemModel)

			local foamRemaining = itemModel:GetAttribute(FOAM_ATTR) or 0
			if foamRemaining <= 0 then return end

			if not data.hitCharacters then return end

			local muzzleAttachment = itemModel:FindFirstChild("MuzzleAttachment") :: Attachment
			local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not hrp then return end

			for _, hitCharacter in data.hitCharacters do
				if typeof(hitCharacter) ~= "Instance" or not hitCharacter:IsA("Model") then continue end
				if hitCharacter == character then continue end

				local humanoid = hitCharacter:FindFirstChildOfClass("Humanoid")
				if not humanoid or humanoid.Health <= 0 then continue end

				local targetHrp = hitCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not targetHrp then continue end

				local pushDirection = targetHrp.Position - (muzzleAttachment and muzzleAttachment.WorldPosition or hrp.Position)
				pushDirection = pushDirection.Magnitude > 0.01 and pushDirection.Unit or Vector3.new(0, 1, 0)

				targetHrp.AssemblyLinearVelocity = pushDirection * item.properties.sprayImpulseForce
			end
		end)

		Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
			local character = leavingPlayer.Character
			local heldItemName = character and character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character and character:FindFirstChild(heldItemName)
			if itemModel then
				_activeDrainLoops[itemModel] = nil
			end
		end)
	else
		Network:BindEvent(EVENT_NAME, "ReplicateFireStart", function(itemModel: Model?)
			if not itemModel then return end
			local emitter = GetMuzzleEmitter(itemModel)
			if emitter then emitter.Enabled = true end
		end)

		Network:BindEvent(EVENT_NAME, "ReplicateFireStop", function(itemModel: Model?)
			if not itemModel then return end
			local emitter = GetMuzzleEmitter(itemModel)
			if emitter then emitter.Enabled = false end
		end)

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

	Network:FireServer(EVENT_NAME, "Equip", _itemModel)

	_currentAnimator = animator

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

	-- Force the fire loop to stop on its next iteration and clean itself up.
	_isFiring = false
	if _fireInputEndedConn then
		_fireInputEndedConn:Disconnect()
		_fireInputEndedConn = nil
	end

	if _idleTrack then
		_idleTrack:Stop(0.15)
		_idleTrack:Destroy()
		_idleTrack = nil
	end

	item.StopFireAnimation()

	Network:FireServer(EVENT_NAME, "Unequip", _itemModel)

	_currentAnimator = nil
end

function item.PlayFireAnimation()
	if RunService:IsServer() then return end
	if not _currentAnimator then return end

	if _fireTrack then
		return -- already looping, don't restart it every tick
	end

	if item.properties.fireAnimationId == 0 then
		return
	end

	local fireAnim = Instance.new("Animation")
	fireAnim.AnimationId = `rbxassetid://{item.properties.fireAnimationId}`

	_fireTrack = _currentAnimator:LoadAnimation(fireAnim)
	_fireTrack.Priority = Enum.AnimationPriority.Action
	_fireTrack.Looped = true
	_fireTrack:Play(0.05)
end

function item.StopFireAnimation()
	if RunService:IsServer() then return end

	if _fireTrack then
		_fireTrack:Stop(0.1)
		_fireTrack:Destroy()
		_fireTrack = nil
	end
end

item.OnInitialize()

return item