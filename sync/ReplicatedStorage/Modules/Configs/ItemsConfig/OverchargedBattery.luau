--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ProjectileSimulation = require(ReplicatedStorage.Modules.Shared.Classes.ProjectileSimulation)

local RagdollService = RunService:IsServer() and require(ServerScriptService.Services.RagdollService) or nil

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

local _pendingConsume: { [Player]: { uid: string, consume: () -> () } } = {}
local PENDING_CONSUME_TIMEOUT = 30

--|| Constants
local EVENT_NAME = `Item_{script.Name}`
local COOLDOWN_ATTR = "LastThrow"
local AWAITING_SETTLE_ATTR = "AwaitingSettle"
local THROW_ORIGIN_ATTR = "ThrowOrigin"

--|| Item ||--
local item = {}

item.properties = {
	cooldown = 8,
	projectileName = "OverchargedBattery",
	throwSpeed = 60,
	gravity = Vector3.new(0, -50, 0),
	elasticity = 0.35,
	radius = 0.5,
	maxLifetime = 8,
	settleThreshold = 2,
	validationThreshold = 25,
	aimCorrectionRange = 1000,

	blastRadius = 12,
	blastForce = 1500,
	minBlastFalloff = 0.35, -- even edge-of-radius characters get at least this fraction of blastForce

	idleAnimationId = 140386882411593,
	throwAnimationId = 138924212256410,

	spawnWeight = 50, -- relative chance to spawn where this item is scattered (higher = more common)
	itemType = "Chaos", -- item-spawn category (ItemSpawnService); "Chaos" | "Non-functional"
}

item.attributes = {
	Rating = 5.0,
	Weight = 1.5,
	MaxWeight = nil,
	IsBag = false,
	IsContraband = true,
}

item.usable = true

--|| Private Functions ||--

local function IsOnCooldown(itemModel: Model): boolean
	local lastThrow = itemModel:GetAttribute(COOLDOWN_ATTR) or 0
	local now = Workspace:GetServerTimeNow()
	return (now - lastThrow) < item.properties.cooldown
end

local function StampCooldown(itemModel: Model)
	itemModel:SetAttribute(COOLDOWN_ATTR, Workspace:GetServerTimeNow())
end

local function ComputeThrowVector(character: Model, itemModel: Model, originCFrame: CFrame, direction: Vector3): (Vector3, Vector3)
	local itemWorldPos = itemModel:GetPivot().Position

	local aimRayParams = RaycastParams.new()
	aimRayParams.FilterType = Enum.RaycastFilterType.Exclude
	aimRayParams.FilterDescendantsInstances = { character, itemModel }

	local aimResult = Workspace:Raycast(
		originCFrame.Position,
		direction.Unit * item.properties.aimCorrectionRange,
		aimRayParams
	)

	local targetPos = aimResult and aimResult.Position
		or (originCFrame.Position + direction.Unit * item.properties.aimCorrectionRange)

	local trueDirection = (targetPos - itemWorldPos).Unit
	local initialVelocity = trueDirection * item.properties.throwSpeed

	return itemWorldPos, initialVelocity
end

local function ExecuteThrow(character: Model, itemModel: Model, originCFrame: CFrame, direction: Vector3, consume: (() -> ())?)
	if IsOnCooldown(itemModel) then return end
	StampCooldown(itemModel)

	local origin, initialVelocity = ComputeThrowVector(character, itemModel, originCFrame, direction)
	local startTime = Workspace:GetServerTimeNow()

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character, Workspace.CurrentCamera }

	local battery = ProjectileSimulation.Ricochet.new({
		name = item.properties.projectileName,
		origin = origin,
		initialVelocity = initialVelocity,
		gravity = item.properties.gravity,
		elasticity = item.properties.elasticity,
		radius = item.properties.radius,
		maxLifetime = item.properties.maxLifetime,
		settleThreshold = item.properties.settleThreshold,
		raycastParams = rayParams,
	})

	local uid = itemModel:GetAttribute("UID")

	Network:FireServer(EVENT_NAME, "ThrowBattery", {
		uid = uid,
		origin = origin,
		velocity = initialVelocity,
		startTime = startTime,
	})

	battery.onHit:Connect(function(settlePosition: Vector3)
		Network:FireServer(EVENT_NAME, "ReportBatterySettled", {
			uid = uid,
			position = settlePosition,
		})
	end)
end

if item.usable then
	item.Use = function(player_: Player, consume: (() -> ())?, originCFrame: CFrame?, direction: Vector3?)
		if RunService:IsServer() then
			local character = player_.Character
			if not character then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel then return end

			local uid = itemModel:GetAttribute("UID")
			if not consume or not uid then return end

			_pendingConsume[player_] = { uid = uid, consume = consume }

			task.delay(PENDING_CONSUME_TIMEOUT, function()
				local pending = _pendingConsume[player_]
				if pending and pending.uid == uid then
					_pendingConsume[player_] = nil
				end
			end)
		elseif RunService:IsClient() then
			if not originCFrame or not direction then return end

			local character = player_.Character
			if not character then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel then return end

			if IsOnCooldown(itemModel) then return end

			item.PlayThrowAnimation()

			local track = item._throwTrack
			if not track then
				ExecuteThrow(character, itemModel, originCFrame, direction, consume)
				return
			end

			local markerConnection: RBXScriptConnection? = nil
			markerConnection = track:GetMarkerReachedSignal("Throw"):Connect(function()
				if markerConnection then
					markerConnection:Disconnect()
					markerConnection = nil
				end

				local currentHeldName = character:GetAttribute("HeldItem")
				local currentItemModel = currentHeldName and character:FindFirstChild(currentHeldName)
				if not currentItemModel then return end

				ExecuteThrow(character, currentItemModel, originCFrame, direction, consume)
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

-- [[ Server-side settle validation + authoritative ragdoll blast ]] --
function item.ReportBatterySettled(reportingPlayer: Player, data: { uid: string?, position: Vector3 })
	local character = reportingPlayer.Character
	if not character then return end

	local awaitingKey = data.uid and `{AWAITING_SETTLE_ATTR}_{data.uid}`
	if not awaitingKey or not character:GetAttribute(awaitingKey) then return end
	character:SetAttribute(awaitingKey, false)

	item._ApplyBlast(data.position)
end

function item._ApplyBlast(position: Vector3)
	if not RagdollService then return end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { Workspace.Debris.Projectiles }

	local parts = Workspace:GetPartBoundsInRadius(position, item.properties.blastRadius, overlapParams)

	-- A character can surface multiple parts in the query — only process each once.
	local processedCharacters: { [Model]: boolean } = {}

	for _, part in parts do
		local character = part:FindFirstAncestorWhichIsA("Model")
		if not character or processedCharacters[character] then continue end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not humanoid or not hrp then continue end

		processedCharacters[character] = true

		local offset = hrp.Position - position
		local distance = offset.Magnitude

		local direction = distance > 0.01 and offset.Unit or Vector3.new(0, 1, 0)

		local force = item.properties.blastForce

		RagdollService.Ragdoll(character, position, direction, force)
	end
end

--|| Initialize ||--
function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then
		Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
			_pendingConsume[leavingPlayer] = nil
		end)

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
		end)

		Network:BindEvent(EVENT_NAME, "ThrowBattery", function(sender: Player, data: { uid: string?, origin: Vector3, velocity: Vector3, startTime: number })
			local character = sender.Character
			if not character then return end
			if not data.uid then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel or itemModel:GetAttribute("UID") ~= data.uid then return end
			if IsOnCooldown(itemModel) then return end
			StampCooldown(itemModel)

			character:SetAttribute(`{THROW_ORIGIN_ATTR}_{data.uid}`, data.origin)
			character:SetAttribute(`{AWAITING_SETTLE_ATTR}_{data.uid}`, true)

			task.delay(item.properties.maxLifetime + 2, function()
				if character and character.Parent then
					character:SetAttribute(`{AWAITING_SETTLE_ATTR}_{data.uid}`, false)
				end
			end)

			Network:FireAllExcept(EVENT_NAME, sender, "ReplicateBatteryThrown", data)

			local pending = _pendingConsume[sender]
			if pending and pending.uid == data.uid then
				_pendingConsume[sender] = nil
				pending.consume()
			end
		end)

		Network:BindEvent(EVENT_NAME, "ReportBatterySettled", function(sender: Player, data: any)
			item.ReportBatterySettled(sender, data)
		end)
	elseif RunService:IsClient() then
		Network:BindEvent(EVENT_NAME, "ReplicateBatteryThrown", function(data: { origin: Vector3, velocity: Vector3, startTime: number })
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude

			ProjectileSimulation.Ricochet.new({
				name = item.properties.projectileName,
				origin = data.origin,
				initialVelocity = data.velocity,
				gravity = item.properties.gravity,
				elasticity = item.properties.elasticity,
				radius = item.properties.radius,
				maxLifetime = item.properties.maxLifetime,
				settleThreshold = item.properties.settleThreshold,
				raycastParams = rayParams,
				startTime = data.startTime,
			})
		end)

		Network:BindEvent(EVENT_NAME, "ForceUnequip", function(itemName: string)
			if itemName ~= script.Name then return end
			item.OnUnequip(player and player.Character and player.Character:FindFirstChild(itemName))
		end)
	end

	_initialized = true
end

--|| Animations ||--
local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil
item._throwTrack = nil :: AnimationTrack?

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

	if item._throwTrack then
		item._throwTrack:Stop(0)
		item._throwTrack:Destroy()
		item._throwTrack = nil
	end

	Network:FireServer(EVENT_NAME, "Unequip", _itemModel)

	_currentAnimator = nil
end

function item.PlayThrowAnimation()
	if RunService:IsServer() then return end

	local animator = GetOrFetchAnimator()
	if not animator then return end

	if item._throwTrack then
		item._throwTrack:Stop(0)
		item._throwTrack:Destroy()
	end

	local throwAnim = Instance.new("Animation")
	throwAnim.AnimationId = `rbxassetid://{item.properties.throwAnimationId}`

	item._throwTrack = animator:LoadAnimation(throwAnim)
	item._throwTrack.Priority = Enum.AnimationPriority.Action
	item._throwTrack.Looped = false
	item._throwTrack:Play(0.05)
end

item.OnInitialize()

return item