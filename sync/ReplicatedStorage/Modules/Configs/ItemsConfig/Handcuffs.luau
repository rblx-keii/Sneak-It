--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

--|| Constants
local EVENT_NAME = `Item_{script.Name}`

--|| Item ||--
local item = {}

item.properties = {
	iconId = 123308856629534,
	conveyorOrientation = CFrame.Angles(math.rad(90), math.rad(0), math.rad(-90)),
	clinkSoundId = 0, -- fill in — handcuffs click sound
	idleAnimationId = 0, -- fill in
}

item.attributes = {
	Rating = 1,
	Weight = 0.5,
}

-- Arresting is a hold-to-cuff interaction (see ArrestController/ArrestService), not a click — there's
-- no Use() function for this item.
item.usable = false

--|| Client-only animation state ||--
local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil

--|| Initialize ||--

function item.OnInitialize()
	if _initialized then return end

	if not RunService:IsServer() then
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

	_currentAnimator = nil
end

item.OnInitialize()

return item
