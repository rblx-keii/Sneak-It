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
	idleAnimationId = 111921936808517
}

item.attributes = {
	Rating = 2.5,
	Weight = 1.0,
	MaxWeight = 5,
	IsBag = true
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

	if RunService:IsServer() then
		-- Server handles secure joint setup for global replication
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

			-- Replicating joint spawned server-side
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

	Network:FireServer(EVENT_NAME, "Equip", _itemModel)

	_currentAnimator = animator

	-- Yield for the server-replicated joint to arrive safely
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

	Network:FireServer(EVENT_NAME, "Unequip", _itemModel)

	_currentAnimator = nil
end

item.OnInitialize()

return item