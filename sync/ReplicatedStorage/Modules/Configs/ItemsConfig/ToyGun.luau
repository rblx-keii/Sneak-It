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
	bonkSoundId = "rbxassetid://137041944943141",
	projectileName = "ToyGunDart",   -- template under Resources.Bullets
	projectileSpeed = 200,           -- studs/sec, fast but visible travel time
	validationThreshold = 6,         -- studs of permissible client/server divergence
	idleAnimationId = 83579299427475,
	fireAnimationId = 140563946311715,

	spawnWeight = 50, -- relative chance to spawn where this item is scattered (higher = more common)
	itemType = "Chaos", -- item-spawn category (ItemSpawnService); "Chaos" | "Non-functional"
}

item.attributes = {
	Rating = 2.0,
	Weight = 1.5
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

			local lastUse = character:GetAttribute("ToyGun_LastUse") or 0
			local now = Workspace:GetServerTimeNow()
			if now - lastUse < item.properties.cooldown then return end
			character:SetAttribute("ToyGun_LastUse", now)

			character:SetAttribute("ToyGun_AwaitingHit", true)
			task.delay(1, function()
				if character and character.Parent then
					character:SetAttribute("ToyGun_AwaitingHit", false)
				end
			end)
		else
			-- [[ CLIENT ]] --
			if not originCFrame or not direction then return end

			local character = player_.Character
			if not character then return end
			local lastUse = character:GetAttribute("ToyGun_LastUse") or 0
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

			Network:FireServer(EVENT_NAME, "ToyGunFired", {
				muzzlePos,
				targetPos,
				workspace:GetServerTimeNow()
			})

			projectile.onHit:Connect(function(result: RaycastResult?)
				if not result then return end

				local hitCharacter = result.Instance:FindFirstAncestorWhichIsA("Model")
				local hitHasHumanoid = hitCharacter and hitCharacter:IsA("Model")
					and hitCharacter:FindFirstChildOfClass("Humanoid") ~= nil

				Network:FireServer(EVENT_NAME, "ReportToyGunHit", {
					hitPosition = result.Position,
					hitInstance = hitHasHumanoid and result.Instance or nil,
				})
			end)
		end
	end
end

-- [[ Server-side hit validation ]] --
function item.ValidateHit(validatingPlayer: Player, data: { hitPosition: Vector3, hitInstance: Instance? })
	local character = validatingPlayer.Character
	if not character then return end

	if not character:GetAttribute("ToyGun_AwaitingHit") then return end
	character:SetAttribute("ToyGun_AwaitingHit", false)

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local distance = (hrp.Position - data.hitPosition).Magnitude
	if distance > item.properties.range + item.properties.validationThreshold then
		warn(`[ToyGun] Hit validation failed for {validatingPlayer.Name}: distance {distance} exceeds range+threshold`)
		return
	end

	if not data.hitInstance then return end

	local hitCharacter = data.hitInstance.Parent
	if not hitCharacter or not hitCharacter:IsA("Model") then return end

	local humanoid = hitCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local sound = Instance.new("Sound")
	sound.SoundId = item.properties.bonkSoundId
	sound.Volume = 1
	sound.Parent = data.hitInstance
	sound:Play()
	game.Debris:AddItem(sound, (sound.TimeLength > 0 and sound.TimeLength or 1) + 0.5)
end

--|| Initialize ||--

function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then
		-- Replicated motor joint mutation setup
		local _lastItemGripWeld: WeldConstraint? = nil
		Network:BindEvent(EVENT_NAME, "Equip", function(playerOwner: Player, _itemModel: Instance?)
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

		Network:BindEvent(EVENT_NAME, "Unequip", function(playerOwner: Player, _itemModel: Instance?)
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

		-- Integrated hit processing directly within your module boundary
		Network:BindEvent(EVENT_NAME, "ReportToyGunHit", function(sender: Player, data: any)
			local record = JailService.GetRecord(sender)
			if not record or record.isJailed then return end

			item.ValidateHit(sender, data)
		end)

		Network:BindEvent(EVENT_NAME, "ToyGunFired", function(player: Player, data: any)
			Network:FireAllExcept(EVENT_NAME, player, "ReplicateToyGunFired", data)
		end)
	else
		Network:BindEvent(EVENT_NAME, "ReplicateToyGunFired", function(data: any)
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

	Network:FireServer(EVENT_NAME, "Unequip", _itemModel)

	_currentAnimator = nil
end

function item.PlayFireAnimation()
	if RunService:IsServer() then return end
	if not _currentAnimator then return end

	if _fireTrack then
		_fireTrack:Stop(0)
		_fireTrack:Destroy()
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