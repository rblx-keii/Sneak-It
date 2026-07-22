--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local player = if not RunService:IsServer() then Players.LocalPlayer else nil

--|| Variables
local _initialized = false

local _pendingAction: { [Player]: { uid: string, resolve: (() -> ())? } } = {}
local PENDING_ACTION_TIMEOUT = 30

local _currentAnimator: Animator? = nil
local _idleTrack: AnimationTrack? = nil
local _useTrack: AnimationTrack? = nil

--|| Constants
local EVENT_NAME = `Item_{script.Name}`
local COOLDOWN_ATTR = "LastUse"
local BUFF_ATTR = "EspressoBuffActive"

--|| Types
export type PendingAction = {
	uid: string,
	resolve: (() -> ())?,
}

--|| Item ||--
local item = {}

item.properties = {
	cooldown = 0, -- single-use consumable, no reuse cooldown needed
	idleAnimationId = 119523608544368,
	useAnimationId = 70544756472581, -- drink animation
	requiresAim = false, -- self-target instant effect

	boostedWalkSpeed = 24,
	duration = 8, -- seconds
}

item.attributes = {
	Rating = 3.0,
	Weight = 1.0,
	MaxWeight = nil,
	IsBag = false,
}

item.usable = true

--|| Private Functions ||--

local function IsOnCooldown(itemModel: Model): boolean
	local lastUse = itemModel:GetAttribute(COOLDOWN_ATTR) or 0
	local now = Workspace:GetServerTimeNow()
	return (now - lastUse) < item.properties.cooldown
end

local function StampCooldown(itemModel: Model)
	itemModel:SetAttribute(COOLDOWN_ATTR, Workspace:GetServerTimeNow())
end

local function GetHeldItemModel(character: Model): Model?
	local heldItemName = character:GetAttribute("HeldItem")
	return heldItemName and character:FindFirstChild(heldItemName) :: Model?
end

-- [[ Item-Specific Effect (SERVER, authoritative) ]] --
function item._ExecuteEffect(player_: Player, itemModel: Model, _actionData: { [string]: any }?)
	local character = player_.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	-- Don't stack the buff if already active
	if character:GetAttribute(BUFF_ATTR) then return end

	character:SetAttribute(BUFF_ATTR, true)

	local originalWalkSpeed = humanoid.WalkSpeed
	humanoid.WalkSpeed = item.properties.boostedWalkSpeed

	Network:FireClient(EVENT_NAME, player_, "EspressoBuffStarted", {
		duration = item.properties.duration,
		startTime = Workspace:GetServerTimeNow(),
	})

	task.delay(item.properties.duration, function()
		if humanoid and humanoid.Parent then
			humanoid.WalkSpeed = originalWalkSpeed
		end

		if character and character.Parent then
			character:SetAttribute(BUFF_ATTR, false)
		end

		Network:FireClient(EVENT_NAME, player_, "EspressoBuffEnded", {})
	end)
end

-- [[ Use Flow ]] --
if item.usable then
	-- CALLING CONVENTION: item.Use(player, consume, originCFrame, direction)
	item.Use = function(player_: Player, consume: (() -> ())?, _originCFrame: CFrame?, _direction: Vector3?)
		if RunService:IsServer() then
			-- [[ SERVER ]] --
			local character = player_.Character
			if not character then return end

			local itemModel = GetHeldItemModel(character)
			if not itemModel then return end

			local uid = itemModel:GetAttribute("UID")
			if not uid then return end

			if IsOnCooldown(itemModel) then return end

			-- Don't resolve/consume immediately — wait for the client to
			-- confirm the drink animation actually played out, same
			-- UID-scoped pending pattern the thrown items use.
			_pendingAction[player_] = { uid = uid, resolve = consume }
			task.delay(PENDING_ACTION_TIMEOUT, function()
				local pending = _pendingAction[player_]
				if pending and pending.uid == uid then
					_pendingAction[player_] = nil
				end
			end)
		else
			-- [[ CLIENT ]] --
			local character = player_.Character
			if not character then return end

			local itemModel = GetHeldItemModel(character)
			if not itemModel then return end

			if IsOnCooldown(itemModel) then return end

			item.PlayUseAnimation()

			local track: AnimationTrack? = item._useTrack
			if not track then
				-- No animation configured — confirm immediately.
				local uid = itemModel:GetAttribute("UID")
				Network:FireServer(EVENT_NAME, "UseItem", { uid = uid })
				return
			end

			track.Stopped:Wait()
			local currentItemModel = GetHeldItemModel(character)
			if not currentItemModel then return end

			local uid = currentItemModel:GetAttribute("UID")
			Network:FireServer(EVENT_NAME, "UseItem", { uid = uid })
		end
	end
end

--|| Initialize ||--
function item.OnInitialize()
	if _initialized then return end

	if RunService:IsServer() then
		-- [[ Hand-equip rig: generic to every held item ]] --
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

		-- [[ Generic "UseItem" resolution for the drink-animation confirm ]] --
		Network:BindEvent(EVENT_NAME, "UseItem", function(sender: Player, data: { uid: string? })
			local character = sender.Character
			if not character then return end
			if not data.uid then return end

			local itemModel = GetHeldItemModel(character)
			if not itemModel or itemModel:GetAttribute("UID") ~= data.uid then return end
			if IsOnCooldown(itemModel) then return end
			StampCooldown(itemModel)

			item._ExecuteEffect(sender, itemModel, nil)

			local pending = _pendingAction[sender]
			if pending and pending.uid == data.uid then
				_pendingAction[sender] = nil
				if pending.resolve then
					pending.resolve()
				end
			end
		end)

		Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
			_pendingAction[leavingPlayer] = nil
		end)
	elseif RunService:IsClient() then
		Network:BindEvent(EVENT_NAME, "EspressoBuffStarted", function(_data: { duration: number, startTime: number })
			-- Hook up buff icon/timer UI here.
		end)

		Network:BindEvent(EVENT_NAME, "EspressoBuffEnded", function()
			-- Hook up buff icon/timer UI teardown here.
		end)

		Network:BindEvent(EVENT_NAME, "ForceUnequip", function(itemName: string)
			if itemName ~= script.Name then return end
			item.OnUnequip(player and player.Character and player.Character:FindFirstChild(itemName))
		end)
	end

	_initialized = true
end

--|| Animations ||--

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

	if item._useTrack then
		item._useTrack:Stop(0)
		item._useTrack:Destroy()
		item._useTrack = nil
	end

	Network:FireServer(EVENT_NAME, "Unequip", _itemModel)

	_currentAnimator = nil
end

function item.PlayUseAnimation()
	if RunService:IsServer() then return end

	local animator = GetOrFetchAnimator()
	if not animator then return end

	if item._useTrack then
		item._useTrack:Stop(0)
		item._useTrack:Destroy()
	end

	if item.properties.useAnimationId == 0 then
		item._useTrack = nil
		return
	end

	local useAnim = Instance.new("Animation")
	useAnim.AnimationId = `rbxassetid://{item.properties.useAnimationId}`

	item._useTrack = animator:LoadAnimation(useAnim)
	item._useTrack.Priority = Enum.AnimationPriority.Action
	item._useTrack.Looped = false
	item._useTrack:Play(0.05)
end

item.OnInitialize()

return item