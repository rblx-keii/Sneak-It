--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ProjectileSimulation = require(ReplicatedStorage.Modules.Shared.Classes.ProjectileSimulation)

local JailService = RunService:IsServer() and require(ServerScriptService.Services.JailService) or nil
local RagdollService = RunService:IsServer() and require(ServerScriptService.Services.RagdollService) or nil

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

--|| Constants
local EVENT_NAME = `Item_{script.Name}`

--|| Item ||--
local item = {}

item.properties = {
	cooldown = 1,                  -- seconds between shots
	range = 120,                   -- studs
	zapSoundId = 0,                 -- fill in — taser zap sound
	projectileName = "TaserDart",    -- template under Resources.Bullets
	projectileSpeed = 200,           -- studs/sec, fast but visible travel time
	validationThreshold = 6,         -- studs of permissible client/server divergence
	ragdollForce = 400,              -- impulse applied to the ragdolled target on hit
	idleAnimationId = 0, -- fill in
	fireAnimationId = 0, -- fill in
}

item.attributes = {
	Rating = 2,
	Weight = 1,
	IsContraband = true,
}

item.usable = true

--|| Client-only animation state ||--
local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil
local _fireTrack: AnimationTrack? = nil

if item.usable then
	-- CALLING CONVENTION: item.Use(player, consume, originCFrame, direction)
	item.Use = function(player_: Player, consume: (() -> ())?, originCFrame: CFrame?, direction: Vector3?)
		if RunService:IsServer() then
			-- [[ SERVER ]] --
			local character = player_.Character
			if not character then return end

			local lastUse = character:GetAttribute("Taser_LastUse") or 0
			local now = Workspace:GetServerTimeNow()
			if now - lastUse < item.properties.cooldown then return end
			character:SetAttribute("Taser_LastUse", now)

			character:SetAttribute("Taser_AwaitingHit", true)
			task.delay(1, function()
				if character and character.Parent then
					character:SetAttribute("Taser_AwaitingHit", false)
				end
			end)
		else
			-- [[ CLIENT ]] --
			if not originCFrame or not direction then return end

			local character = player_.Character
			if not character then return end
			local lastUse = character:GetAttribute("Taser_LastUse") or 0
			local now = Workspace:GetServerTimeNow()
			if now - lastUse < item.properties.cooldown then return end

			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.FilterDescendantsInstances = { character }

			local result = Workspace:Raycast(originCFrame.Position, direction.Unit * item.properties.range, rayParams)
			local targetPos = result and result.Position or (originCFrame.Position + direction.Unit * item.properties.range)

			local muzzlePos = originCFrame.Position
			local heldItemName = character:GetAttribute("HeldItem")
			local heldModel = heldItemName and character:FindFirstChild(heldItemName)
			local muzzleAttachment = heldModel and heldModel:FindFirstChild("MuzzleAttachment", true) :: Attachment?
			if muzzleAttachment then
				muzzlePos = muzzleAttachment.WorldPosition
			end

			item.PlayFireAnimation()

			local projectile = ProjectileSimulation.Projectile.new(
				item.properties.projectileName,
				muzzlePos,
				targetPos,
				item.properties.projectileSpeed,
				nil,
				rayParams
			)

			Network:FireServer(EVENT_NAME, "TaserFired", {
				muzzlePos,
				targetPos,
				workspace:GetServerTimeNow()
			})

			projectile.onHit:Connect(function(result: RaycastResult?)
				if not result then return end

				local hitCharacter = result.Instance:FindFirstAncestorWhichIsA("Model")
				local hitHasHumanoid = hitCharacter and hitCharacter:IsA("Model")
					and hitCharacter:FindFirstChildOfClass("Humanoid") ~= nil

				Network:FireServer(EVENT_NAME, "ReportTaserHit", {
					hitPosition = result.Position,
					hitInstance = hitHasHumanoid and result.Instance or nil,
				})
			end)
		end
	end
end

-- [[ Server-side hit validation + ragdoll ]] --
function item.ValidateHit(shooter: Player, data: { hitPosition: Vector3, hitInstance: Instance? })
	local character = shooter.Character
	if not character then return end

	if not character:GetAttribute("Taser_AwaitingHit") then return end
	character:SetAttribute("Taser_AwaitingHit", false)

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local distance = (hrp.Position - data.hitPosition).Magnitude
	if distance > item.properties.range + item.properties.validationThreshold then
		warn(`[Taser] Hit validation failed for {shooter.Name}: distance {distance} exceeds range+threshold`)
		return
	end

	if not data.hitInstance then return end

	local hitCharacter = data.hitInstance.Parent
	if not hitCharacter or not hitCharacter:IsA("Model") then return end

	local humanoid = hitCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	if item.properties.zapSoundId ~= 0 then
		local sound = Instance.new("Sound")
		sound.SoundId = `rbxassetid://{item.properties.zapSoundId}`
		sound.Volume = 1
		sound.Parent = data.hitInstance
		sound:Play()
		game.Debris:AddItem(sound, (sound.TimeLength > 0 and sound.TimeLength or 1) + 0.5)
	end

	local target: Player | Model = Players:GetPlayerFromCharacter(hitCharacter) or hitCharacter
	local direction = (data.hitPosition - hrp.Position)
	direction = direction.Magnitude > 0 and direction.Unit or Vector3.new(0, 0, -1)

	RagdollService.Ragdoll(target, data.hitPosition, direction, item.properties.ragdollForce)
end

--|| Initialize ||--

function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then

		Network:BindEvent(EVENT_NAME, "ReportTaserHit", function(sender: Player, data: any)
			local record = JailService.GetRecord(sender)
			if not record or record.isJailed then return end

			item.ValidateHit(sender, data)
		end)

		Network:BindEvent(EVENT_NAME, "TaserFired", function(player: Player, data: any)
			Network:FireAllExcept(EVENT_NAME, player, "ReplicateTaserFired", data)
		end)
	else
		Network:BindEvent(EVENT_NAME, "ReplicateTaserFired", function(data: any)
			ProjectileSimulation.Projectile.new(
				item.properties.projectileName,
				data[1],
				data[2],
				item.properties.projectileSpeed,
				data[3]
			)
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

	if _fireTrack then
		_fireTrack:Stop(0)
		_fireTrack:Destroy()
		_fireTrack = nil
	end

	_currentAnimator = nil
end

function item.PlayFireAnimation()
	if RunService:IsServer() then return end
	if not _currentAnimator then return end

	if _fireTrack then
		_fireTrack:Stop(0)
		_fireTrack:Destroy()
	end

	if item.properties.fireAnimationId == 0 then
		_fireTrack = nil
		return
	end

	local fireAnim = Instance.new("Animation")
	fireAnim.AnimationId = `rbxassetid://{item.properties.fireAnimationId}`

	_fireTrack = _currentAnimator:LoadAnimation(fireAnim)
	_fireTrack.Priority = Enum.AnimationPriority.Action
	_fireTrack.Looped = false
	_fireTrack:Play(0.05)
end

item.OnInitialize()

return item
