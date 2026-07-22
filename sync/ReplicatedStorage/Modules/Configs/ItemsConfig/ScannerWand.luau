--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local JailService = RunService:IsServer() and require(ServerScriptService.Services.JailService) or nil
local DataService = RunService:IsServer() and require(ServerScriptService.Services.DataService) or nil

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

-- SERVER: keyed by the Scanner BasePart, incremented each scan. A pending
-- revert only applies its color change if its token still matches — this
-- stops an older scan's revert timer from stomping a newer scan's result
-- if two scans land within scannerResetDelay of each other.
local _scannerRevertTokens: { [BasePart]: number } = {}

--|| Constants
local EVENT_NAME = `Item_{script.Name}`
local COOLDOWN_ATTR = "LastScan"
local AWAITING_SCAN_ATTR = "AwaitingScan"

--|| Item ||--
local item = {}

item.properties = {
	cooldown = 1,
	range = 15, -- short — this is a wand check, not a weapon
	validationThreshold = 4,
	greenSoundId = "rbxassetid://139657844452550", -- fill in — clean beep
	redSoundId = "rbxassetid://72577143736585",   -- fill in — contraband buzzer

	greenColor = Color3.fromRGB(60, 220, 90),
	redColor = Color3.fromRGB(220, 50, 50),
	scannerResetDelay = 2, -- seconds before the Scanner part returns to its original color

	idleAnimationId = 85777415279781,
	useAnimationId = 0, -- optional quick "wave the wand" animation
}

item.attributes = {
	Rating = 2.5,
	Weight = 1.5,
}

item.usable = true

--|| Client-only animation state ||--
local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil
local _useTrack: AnimationTrack? = nil

--|| Private Functions ||--

local function IsOnCooldown(itemModel: Model): boolean
	local lastScan = itemModel:GetAttribute(COOLDOWN_ATTR) or 0
	local now = Workspace:GetServerTimeNow()
	return (now - lastScan) < item.properties.cooldown
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

			local awaitingKey = `{AWAITING_SCAN_ATTR}_{uid}`
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

			local scannerPart = itemModel:FindFirstChild("Scanner"):: BasePart

			item.PlayUseAnimation()

			-- Basic raycasting / Mouse.Target — instant, no travel projectile.
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.FilterDescendantsInstances = { character }

			local result = Workspace:Raycast(originCFrame.Position, direction.Unit * 100, rayParams)
			if not result then return end

			local hitCharacter = result.Instance:FindFirstAncestorWhichIsA("Model")
			local hitHasHumanoid = hitCharacter and hitCharacter:IsA("Model")
				and hitCharacter:FindFirstChildOfClass("Humanoid") ~= nil

			local uid = itemModel:GetAttribute("UID")

			Network:FireServer(EVENT_NAME, "ReportScan", {
				uid = uid,
				hitPosition = result.Position,
				hitInstance = hitHasHumanoid and result.Instance or nil,
			})
		end
	end
end

-- [[ Server-side scan validation + result sound ]] --
function item.ValidateScan(validatingPlayer: Player, data: { uid: string?, hitPosition: Vector3, hitInstance: Instance? })
	local character = validatingPlayer.Character
	if not character then return end
	if not data.uid then return end

	local awaitingKey = `{AWAITING_SCAN_ATTR}_{data.uid}`
	if not character:GetAttribute(awaitingKey) then return end
	character:SetAttribute(awaitingKey, false)

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	if not data.hitInstance then return end

	local hitCharacter = data.hitInstance:FindFirstAncestorWhichIsA("Model")
	if not hitCharacter or not hitCharacter:IsA("Model") then return end
	if not hitCharacter:FindFirstChildOfClass("Humanoid") then return end

	if (hrp.Position - data.hitPosition).Magnitude > item.properties.range then return end

	local hasContraband = hitCharacter:GetAttribute("HasContraband") == true

	DataService.UpdateData(validatingPlayer, { type = "UpdateProfile", data = { key = "totalSearches", amount = 1 } })

	if hasContraband then
		DataService.UpdateData(validatingPlayer, { type = "UpdateProfile", data = { key = "successfulSearches", amount = 1 } })
	else
		local targetPlayer = Players:GetPlayerFromCharacter(hitCharacter)
		if targetPlayer then
			DataService.UpdateData(targetPlayer, { type = "UpdateProfile", data = { key = "successfulSearchEvades", amount = 1 } })
		end
	end

	local sound = Instance.new("Sound")
	sound.SoundId = hasContraband and item.properties.redSoundId or item.properties.greenSoundId
	sound.Volume = 1
	sound.Parent = data.hitInstance
	sound:Play()
	game.Debris:AddItem(sound, (sound.TimeLength > 0 and sound.TimeLength or 1) + 0.5)

	local heldItemName = character:GetAttribute("HeldItem")
	local itemModel = heldItemName and character:FindFirstChild(heldItemName)
	local scannerPart = itemModel and itemModel:FindFirstChild("Scanner") :: BasePart?

	if scannerPart then
		local originalColor = scannerPart:GetAttribute("OriginalColor")
		if typeof(originalColor) ~= "Color3" then
			originalColor = scannerPart.Color
			scannerPart:SetAttribute("OriginalColor", originalColor)
		end

		scannerPart.Color = hasContraband and item.properties.redColor or item.properties.greenColor

		local token = (_scannerRevertTokens[scannerPart] or 0) + 1
		_scannerRevertTokens[scannerPart] = token

		task.delay(item.properties.scannerResetDelay, function()
			if _scannerRevertTokens[scannerPart] ~= token then return end -- superseded by a newer scan
			if scannerPart and scannerPart.Parent then
				scannerPart.Color = originalColor
			end
		end)
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
		end)

		Network:BindEvent(EVENT_NAME, "ReportScan", function(sender: Player, data: any)
			local character = sender.Character
			if not character then return end

			local heldItemName = character:GetAttribute("HeldItem")
			local itemModel = heldItemName and character:FindFirstChild(heldItemName)
			if not itemModel then return end
			if IsOnCooldown(itemModel) then return end

			local record = JailService.GetRecord(sender)
			if not record or record.isJailed then return end

			StampCooldown(itemModel)
			item.ValidateScan(sender, data)
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

	if _useTrack then
		_useTrack:Stop(0)
		_useTrack:Destroy()
		_useTrack = nil
	end

	Network:FireServer(EVENT_NAME, "Unequip", _itemModel)

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