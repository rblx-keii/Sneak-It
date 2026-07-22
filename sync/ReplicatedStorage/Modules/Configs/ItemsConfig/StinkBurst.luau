--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ProjectileSimulation = require(ReplicatedStorage.Modules.Shared.Classes.ProjectileSimulation)

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
local STINK_AFFECTED_ATTR = "StinkAffected"
local COUGH_SOUND_ID = "rbxassetid://116385785266010" -- fill in

--|| Item ||--
local item = {}

item.properties = {
	cooldown = 8,
	projectileName = "StinkBurst",
	throwSpeed = 60,
	gravity = Vector3.new(0, -50, 0),
	elasticity = 0.35,
	radius = 0.5,
	maxLifetime = 8,
	settleThreshold = 2,
	validationThreshold = 25,
	aimCorrectionRange = 1000,

	zoneRadius = 12,
	zoneDuration = 10,
	walkSpeedMultiplier = 0.5,
	checkInterval = 0.25, -- how often (seconds) the zone re-checks who's inside

	cloudRadius = 12,
	cloudDuration = 10,

	idleAnimationId = 121572869779838,
	throwAnimationId = 139545597914567,

	spawnWeight = 50, -- relative chance to spawn where this item is scattered (higher = more common)
	itemType = "Chaos", -- item-spawn category (ItemSpawnService); "Chaos" | "Non-functional"
}

item.attributes = {
	Rating = 3.5,
	Weight = 2.0,
	MaxWeight = nil,
	IsBag = false,
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

	local stinkBomb = ProjectileSimulation.Ricochet.new({
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

	Network:FireServer(EVENT_NAME, "ThrowStinkBomb", {
		uid = uid,
		origin = origin,
		velocity = initialVelocity,
		startTime = startTime,
	})

	stinkBomb.onHit:Connect(function(settlePosition: Vector3)
		Network:FireServer(EVENT_NAME, "ReportStinkSettled", {
			uid = uid,
			position = settlePosition,
		})
	end)
end

type StinkState = { originalSpeed: number, coughSound: Sound }

local function SetStinkAffected(character: Model, humanoid: Humanoid, zoneState: { [Model]: StinkState }, affected: boolean)
	if affected then
		if character:GetAttribute(STINK_AFFECTED_ATTR) then return end
		character:SetAttribute(STINK_AFFECTED_ATTR, true)

		local coughSound = Instance.new("Sound")
		coughSound.SoundId = COUGH_SOUND_ID
		coughSound.Volume = 1
		coughSound.Looped = true
		local hrp = character:FindFirstChild("HumanoidRootPart")
		coughSound.Parent = hrp or character
		coughSound:Play()

		zoneState[character] = {
			originalSpeed = humanoid.WalkSpeed,
			coughSound = coughSound,
		}
		humanoid.WalkSpeed = humanoid.WalkSpeed * item.properties.walkSpeedMultiplier
	else
		if not character:GetAttribute(STINK_AFFECTED_ATTR) then return end
		character:SetAttribute(STINK_AFFECTED_ATTR, false)

		local state = zoneState[character]
		if state then
			if humanoid and humanoid.Parent then
				humanoid.WalkSpeed = state.originalSpeed
			end
			if state.coughSound then
				state.coughSound:Stop()
				state.coughSound:Destroy()
			end
		end
		zoneState[character] = nil
	end
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

-- [[ Server-side settle validation + authoritative stink zone ]] --
function item.ReportStinkSettled(reportingPlayer: Player, data: { uid: string?, position: Vector3 })
	local character = reportingPlayer.Character
	if not character then return end

	local awaitingKey = data.uid and `{AWAITING_SETTLE_ATTR}_{data.uid}`
	if not awaitingKey or not character:GetAttribute(awaitingKey) then return end
	character:SetAttribute(awaitingKey, false)

	item._SpawnZone(data.position)
	item._SpawnCloud(data.position)
end

function item._SpawnZone(position: Vector3)
	local zoneState: { [Model]: StinkState } = {}
	local elapsed = 0

	local heartbeatConnection: RBXScriptConnection? = nil
	heartbeatConnection = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed < item.properties.checkInterval then return end
		elapsed = 0

		local insideNow: { [Model]: boolean } = {}

		for _, plr in Players:GetPlayers() do
			local otherCharacter = plr.Character
			local humanoid = otherCharacter and otherCharacter:FindFirstChildOfClass("Humanoid")
			local hrp = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not otherCharacter or not humanoid or not hrp then continue end

			local distance = (hrp.Position - position).Magnitude
			if distance <= item.properties.zoneRadius then
				insideNow[otherCharacter] = true
				SetStinkAffected(otherCharacter, humanoid, zoneState, true)
			end
		end

		-- Un-affect anyone who was inside but has now left
		for affectedCharacter in zoneState do
			if not insideNow[affectedCharacter] then
				local humanoid = affectedCharacter:FindFirstChildOfClass("Humanoid")
				if humanoid then
					SetStinkAffected(affectedCharacter, humanoid, zoneState, false)
				end
			end
		end
	end)

	task.delay(item.properties.zoneDuration, function()
		if heartbeatConnection then
			heartbeatConnection:Disconnect()
			heartbeatConnection = nil
		end

		-- Restore anyone still inside when the zone expires
		for affectedCharacter in zoneState do
			local humanoid = affectedCharacter:FindFirstChildOfClass("Humanoid")
			if humanoid then
				SetStinkAffected(affectedCharacter, humanoid, zoneState, false)
			end
		end
	end)
end

function item._SpawnCloud(position: Vector3)
	local cloudPart = Instance.new("Part")
	cloudPart.Name = "StinkBombCloud"
	cloudPart.Anchored = true
	cloudPart.CanCollide = false
	cloudPart.CanTouch = false
	cloudPart.Transparency = 1
	cloudPart.Size = Vector3.new(1, 1, 1)
	cloudPart.CFrame = CFrame.new(position)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "StinkEmitter"
	emitter.Color = ColorSequence.new(Color3.fromRGB(120, 120, 120))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, item.properties.cloudRadius),
		NumberSequenceKeypoint.new(1, item.properties.cloudRadius * 1.2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.8, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(item.properties.cloudDuration * 0.6, item.properties.cloudDuration * 0.8)
	emitter.Rate = 40
	emitter.Speed = NumberRange.new(1, 4)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Parent = cloudPart
	emitter.Texture = "rbxassetid://5145149803"
	cloudPart.Parent = Workspace.Debris.Effects

	task.delay(item.properties.cloudDuration * 0.7, function()
		if emitter and emitter.Parent then
			emitter.Enabled = false
		end
	end)

	game.Debris:AddItem(cloudPart, item.properties.cloudDuration)
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

		Network:BindEvent(EVENT_NAME, "ThrowStinkBomb", function(sender: Player, data: { uid: string?, origin: Vector3, velocity: Vector3, startTime: number })
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

			Network:FireAllExcept(EVENT_NAME, sender, "ReplicateStinkBombThrown", data)

			local pending = _pendingConsume[sender]
			if pending and pending.uid == data.uid then
				_pendingConsume[sender] = nil
				pending.consume()
			end
		end)

		Network:BindEvent(EVENT_NAME, "ReportStinkSettled", function(sender: Player, data: any)
			item.ReportStinkSettled(sender, data)
		end)
	elseif RunService:IsClient() then
		Network:BindEvent(EVENT_NAME, "ReplicateStinkBombThrown", function(data: { origin: Vector3, velocity: Vector3, startTime: number })
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