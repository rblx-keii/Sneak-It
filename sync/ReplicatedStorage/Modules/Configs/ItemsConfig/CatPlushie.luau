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
	iconId = 105713257008051, -- item icon asset id
	idleAnimationId = 0, -- fill in
	spawnWeight = 45, -- relative chance to spawn where this item is scattered (higher = more common)
	itemType = "Non-functional", -- item-spawn category (ItemSpawnService); "Chaos" | "Non-functional"
}

item.attributes = {
	Rating = 2.5,
	Weight = 1.5,
	IsBag = false,
	IsContraband = true,
}

item.usable = false

if item.usable then
	item.Use = function(...)
		-- Use functionality
	end
end

--|| Initialize ||--

function item.OnInitialize()
	if _initialized then return end

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
