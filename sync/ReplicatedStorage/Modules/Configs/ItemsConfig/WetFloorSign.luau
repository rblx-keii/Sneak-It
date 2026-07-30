--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local RagdollService = RunService:IsServer() and require(ServerScriptService.Services.RagdollService) or nil

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

-- [[ Server-only state ]] --
local _activeSignByOwner: { [Player]: Model } = {}
local _touchDebounce: { [BasePart]: { [Model]: boolean } } = {}
local _lastDeployByPlayer: { [Player]: number } = {}

--|| Constants
local EVENT_NAME = `Item_{script.Name}`

--|| Item ||--
local item = {}

item.properties = {
	cooldown = 5,
	placementDistance = 3,
	floorRaycastDrop = 20,
	ragdollDuration = 2,
	triggerCooldown = 5,
	ownerGracePeriod = 3,
	lifetime = 30,
	signModelName = "WetFloorSign",   -- template Model under ReplicatedStorage.Assets.Traps
	puddleSize = Vector3.new(7, 0.5, 7),
	puddleColor = Color3.fromRGB(40, 130, 220),
	puddleTweenTime = 0.4,
	idleAnimationId = 99566760425681,

	spawnWeight = 50, -- relative chance to spawn where this item is scattered (higher = more common)
	itemType = "Chaos", -- item-spawn category (ItemSpawnService); "Chaos" | "Non-functional"
}

item.attributes = {
	Rating = 3.5,
	Weight = 4.5,
	MaxWeight = 15,
	IsBag = false,
	IsContraband = true,
}

item.usable = true

if item.usable then
	item.Use = function(player_: Player, consume: (() -> ())?, originCFrame: CFrame?, direction: Vector3?)
		if RunService:IsServer() then
			if consume then consume() end
		elseif RunService:IsClient() then
			local character = player_.Character
			if not character then return end

			local lastUse = character:GetAttribute("WetFloorSign_LastUse") or 0
			local now = Workspace:GetServerTimeNow()
			if now - lastUse < item.properties.cooldown then return end
			character:SetAttribute("WetFloorSign_LastUse", now)

			Network:FireServer(EVENT_NAME, "DeploySign", {})

			if consume then
				consume()
			end
		end
	end
end

-- [[ Server-side placement — position derived from the player's character ]] --
function item.DeploySign(deployingPlayer: Player)
	local now = Workspace:GetServerTimeNow()
	local lastDeploy = _lastDeployByPlayer[deployingPlayer] or 0
	if now - lastDeploy < item.properties.cooldown then
		warn(`[WetFloorSign] {deployingPlayer.Name} attempted to deploy before cooldown expired`)
		return
	end
	_lastDeployByPlayer[deployingPlayer] = now

	local character = deployingPlayer.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local lookDir = hrp.CFrame.LookVector
	local aimPoint = hrp.Position + (lookDir * item.properties.placementDistance)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local rayOrigin = aimPoint + Vector3.new(0, 5, 0)
	local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -item.properties.floorRaycastDrop, 0), rayParams)

	local floorPosition = rayResult and rayResult.Position or aimPoint
	local floorNormal = rayResult and rayResult.Normal or Vector3.yAxis

	local existing = _activeSignByOwner[deployingPlayer]
	if existing and existing.Parent then
		existing:Destroy()
	end
	_activeSignByOwner[deployingPlayer] = nil

	local signContainer = Instance.new("Model")
	signContainer.Name = "WetFloorSign"

	local template = ReplicatedStorage.Assets.Traps:FindFirstChild(item.properties.signModelName)
	local visualModel: Model?

	if template and template:IsA("Model") then
		visualModel = template:Clone()
	else
		warn(`[WetFloorSign] No trap template Model found for "{item.properties.signModelName}" in ReplicatedStorage.Assets.Traps`)
	end

	if visualModel then
		local extentsSize = visualModel:GetExtentsSize()
		local extentsCFrame = visualModel:GetBoundingBox()
		local originCFrame = visualModel:GetPivot()

		local pivotToExtentsCenter = originCFrame:ToObjectSpace(extentsCFrame).Position

		local signCFrame = CFrame.new(floorPosition, floorPosition + floorNormal) * CFrame.Angles(math.rad(-90), 0, 0)

		local halfHeightOffset = Vector3.new(0, extentsSize.Y / 2, 0)
		local correctedCFrame = signCFrame * CFrame.new(halfHeightOffset - pivotToExtentsCenter)

		visualModel:PivotTo(correctedCFrame)

		for _, descendant in visualModel:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
			end
		end

		visualModel.Parent = signContainer
	end

	local puddleModel = Instance.new("Model")
	puddleModel.Name = "Puddle"

	local puddlePart = Instance.new("Part")
	puddlePart.Name = "PuddlePart"
	puddlePart.Anchored = true
	puddlePart.CanCollide = false
	puddlePart.CanTouch = true
	puddlePart.Material = Enum.Material.SmoothPlastic
	puddlePart.Color = item.properties.puddleColor
	puddlePart.Transparency = 0.35

	local finalSize = item.properties.puddleSize
	puddlePart.Size = Vector3.new(0.1, finalSize.Y, 0.1)
	puddlePart.CFrame = CFrame.new(floorPosition + Vector3.new(0, finalSize.Y / 2, 0))
	puddlePart.Parent = puddleModel
	puddleModel.PrimaryPart = puddlePart

	puddleModel.Parent = signContainer

	TweenService:Create(
		puddlePart,
		TweenInfo.new(item.properties.puddleTweenTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = finalSize }
	):Play()

	signContainer:SetAttribute("Owner", deployingPlayer.UserId)
	signContainer.Parent = Workspace.Debris.Traps

	_activeSignByOwner[deployingPlayer] = signContainer
	_touchDebounce[puddlePart] = {}

	local placedAt = now

	local touchConnection: RBXScriptConnection
	touchConnection = puddlePart.Touched:Connect(function(hit: BasePart)
		item._OnPuddleTouched(puddlePart, hit, deployingPlayer, placedAt)
	end)

	game.Debris:AddItem(signContainer, item.properties.lifetime)
	task.delay(item.properties.lifetime, function()
		if touchConnection then
			touchConnection:Disconnect()
		end
		_touchDebounce[puddlePart] = nil
		if _activeSignByOwner[deployingPlayer] == signContainer then
			_activeSignByOwner[deployingPlayer] = nil
		end
	end)
end

function item._OnPuddleTouched(puddlePart: BasePart, hit: BasePart, owner: Player, placedAt: number)
	local hitCharacter = hit.Parent
	if not hitCharacter or not hitCharacter:IsA("Model") then return end

	local humanoid = hitCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local hitPlayer = Players:GetPlayerFromCharacter(hitCharacter)
	if hitPlayer == owner then
		local elapsed = Workspace:GetServerTimeNow() - placedAt
		if elapsed < item.properties.ownerGracePeriod then
			return
		end
	end

	local debounceSet = _touchDebounce[puddlePart]
	if not debounceSet then return end
	if debounceSet[hitCharacter] then return end

	debounceSet[hitCharacter] = true
	task.delay(item.properties.triggerCooldown, function()
		local currentSet = _touchDebounce[puddlePart]
		if currentSet then
			currentSet[hitCharacter] = nil
		end
	end)

	RagdollService.Ragdoll(hitCharacter, hitCharacter:GetPivot().Position, hitCharacter:GetPivot().LookVector * 1.5, 175)

	task.delay(item.properties.ragdollDuration, function()
		RagdollService.Restore(hitCharacter)
	end)
end

--|| Initialize ||--

function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then

		Network:BindEvent(EVENT_NAME, "DeploySign", function(sender: Player, _data: any)
			item.DeploySign(sender)
		end)

		Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
			local sign = _activeSignByOwner[leavingPlayer]
			if sign and sign.Parent then
				sign:Destroy()
			end
			_activeSignByOwner[leavingPlayer] = nil
			_lastDeployByPlayer[leavingPlayer] = nil
		end)
	end

	_initialized = true
end

--|| Animations ||--

local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil

function item.OnEquip(_itemModel: Instance?)
	if RunService:IsServer() then return end
	if not player or not player.Character then return end

	local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end

	_currentAnimator = animator

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

	_currentAnimator = nil
end

item.OnInitialize()

return item