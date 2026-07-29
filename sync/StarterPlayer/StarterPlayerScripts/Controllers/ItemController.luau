--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local InputController = require(ReplicatedStorage.Modules.Shared.InputController)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)

local player = Players.LocalPlayer

local ActionPromptController = require(script.Parent.Gui.ActionPrompt)
local CameraController = require(script.Parent.CameraController)

--|| Variables
local _stopCharacterObserver: (() -> ())? = nil

local _throwHandle: InputController.ActionHandle? = nil
local _dropHandle: InputController.ActionHandle? = nil
local _useHandle: InputController.ActionHandle? = nil
local _popHandle: InputController.ActionHandle? = nil

local _currentItem: string? = nil
local _isEquipped: boolean = false
local _isHoldingBag: boolean = false
local _currentAnimator: Animator? = nil

--|| Constants
local THROW_ACTION = "Item_Throw"
local DROP_ACTION = "Item_Drop"
local USE_ACTION = "Item_Use"
local POP_ACTION = "Item_Pop"

local THROW_INPUT = Enum.KeyCode.F
local DROP_INPUT = Enum.KeyCode.G
local USE_INPUT = Enum.UserInputType.MouseButton1
local POP_INPUT = Enum.KeyCode.Q

local THROW_ANIMATION_ID = 106980214548532

local THROW_ANIM_INSTANCE = Instance.new("Animation")
THROW_ANIM_INSTANCE.AnimationId = `rbxassetid://{THROW_ANIMATION_ID}`

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Signals ]] --
Shared.OnItemEquipped = ModuleUtils.signal.new()
Shared.OnItemUnequipped = ModuleUtils.signal.new()

-- [[ Startup ]] --
function Shared.Init()
	_stopCharacterObserver = Observers.observeLocalCharacter(function(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if humanoid then
			_currentAnimator = humanoid:WaitForChild("Animator", 5) :: Animator?
		end

		local stopAttribute = Observers.observeAttribute(character, "HeldItem", function(heldItemName)
			local previousItem = _currentItem

			_isEquipped = (heldItemName ~= nil and heldItemName ~= "")
			_currentItem = heldItemName ~= "" and heldItemName or nil

			if _isEquipped then
				local heldItem = character:FindFirstChild(heldItemName)
				_isHoldingBag = heldItem and (heldItem:GetAttribute("IsBag") == true) or false
				Local.BindActions()

				if _currentItem ~= previousItem then
					Shared.OnItemEquipped:Fire(_currentItem, heldItem)
				end
			else
				_isHoldingBag = false
				Local.UnbindActions()
			end
		end)

		return function()
			stopAttribute()
			Local.UnbindActions()

			if _currentItem then
				Shared.OnItemUnequipped:Fire(_currentItem, nil)
			end

			_isEquipped = false
			_isHoldingBag = false
			_currentItem = nil
			_currentAnimator = nil
		end
	end)

	Observers.observeTag("Interactable", function(instance: Instance): (() -> ())?  
		local itemConfig = ItemsConfig.GetItem(instance.Name)
		if not itemConfig then 
			warn(`[ItemController] No item config found for {instance.Name}`)
			return
		end

		return function()

		end
	end)

	Network:BindEvent("Item", "ForceUnequip", function(_instance: Instance)
		if not _instance then return end
		local item = ItemsConfig.GetItem(_instance.Name)
		if not item then 
			warn(`[ItemController] No item config found for {_instance.Name}`)
			return 
		end

		if item.OnUnequip then
			item.OnUnequip(_instance)
		end
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.OnThrowInput(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	if not _isEquipped or not _currentAnimator then return Enum.ContextActionResult.Pass end

	local camera = Workspace.CurrentCamera
	if not camera then return Enum.ContextActionResult.Pass end

	local throwTrack = _currentAnimator:LoadAnimation(THROW_ANIM_INSTANCE)
	throwTrack.Priority = Enum.AnimationPriority.Action
	throwTrack:Play()

	local markerConnection: RBXScriptConnection? = nil
	markerConnection = throwTrack:GetMarkerReachedSignal("Throw"):Connect(function()
		if markerConnection then
			markerConnection:Disconnect()
			markerConnection = nil
		end

		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

		local cf: CFrame
		if CameraController.IsFreeLook() and hrp then
			cf = hrp.CFrame
		else
			cf = camera.CFrame
		end

		Shared.OnItemUnequipped:Fire(_currentItem, player.Character and player.Character:FindFirstChild(_currentItem))

		Network:FireServer("Item", "RequestThrow", {
			origin = cf,
			direction = cf.LookVector
		})
	end)

	throwTrack.Stopped:Connect(function()
		if markerConnection then
			markerConnection:Disconnect()
			markerConnection = nil
		end
	end)

	return Enum.ContextActionResult.Sink
end

function Local.OnDropInput(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	if not _isEquipped then return Enum.ContextActionResult.Pass end

	Shared.OnItemUnequipped:Fire(_currentItem, player.Character and player.Character:FindFirstChild(_currentItem))

	Network:FireServer("Item", "RequestDrop", {})
	return Enum.ContextActionResult.Sink
end

function Local.OnUseInput(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	if not _isEquipped or not _currentItem then return Enum.ContextActionResult.Pass end

	local camera = Workspace.CurrentCamera
	if not camera then return Enum.ContextActionResult.Pass end

	local cf = camera.CFrame

	local itemModule = ItemsConfig.GetItem(_currentItem)
	if itemModule and itemModule.Use then
		task.defer(function()
			itemModule.Use(player, nil, cf, cf.LookVector)
		end)
	end

	Network:FireServer("Item", "RequestUse", {
		origin = cf,
		direction = cf.LookVector,
	})

	return Enum.ContextActionResult.Sink
end

function Local.OnPopInput(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	if not _isHoldingBag then return Enum.ContextActionResult.Pass end

	Network:FireServer("Item", "RequestPop", {})
	return Enum.ContextActionResult.Sink
end

function Local.BindActions()
	if not _throwHandle then
		_throwHandle = InputController.BindAction({
			name = THROW_ACTION,
			keys = { THROW_INPUT },
			priority = Enum.ContextActionPriority.High.Value,
			callback = Local.OnThrowInput
		})
	end
	if not _dropHandle then
		_dropHandle = InputController.BindAction({
			name = DROP_ACTION,
			keys = { DROP_INPUT },
			priority = Enum.ContextActionPriority.High.Value,
			callback = Local.OnDropInput
		})
	end

	ActionPromptController.ShowPrompt(Enum.KeyCode.F, "Throw Item")
	ActionPromptController.ShowPrompt(Enum.KeyCode.G, "Drop Item")

	if _currentItem and ItemsConfig.IsItemUsable(_currentItem) then
		if not _useHandle then
			_useHandle = InputController.BindAction({
				name = USE_ACTION,
				keys = { USE_INPUT },
				priority = Enum.ContextActionPriority.High.Value,
				callback = Local.OnUseInput
			})
		end

		ActionPromptController.ShowPrompt(Enum.UserInputType.MouseButton1, "Use Item")
	end

	if _isHoldingBag and not _popHandle then
		_popHandle = InputController.BindAction({
			name = POP_ACTION,
			keys = { POP_INPUT },
			priority = Enum.ContextActionPriority.High.Value,
			callback = Local.OnPopInput
		})
		ActionPromptController.ShowPrompt(Enum.KeyCode.Q, "Take out Item")
	end
end

function Local.UnbindActions()
	if _throwHandle then _throwHandle:Unbind(); _throwHandle = nil end
	if _dropHandle then _dropHandle:Unbind(); _dropHandle = nil end
	if _useHandle then _useHandle:Unbind(); _useHandle = nil end
	if _popHandle then _popHandle:Unbind(); _popHandle = nil end

	ActionPromptController.HidePrompt(Enum.KeyCode.F)
	ActionPromptController.HidePrompt(Enum.KeyCode.G)
	ActionPromptController.HidePrompt(Enum.UserInputType.MouseButton1)
	ActionPromptController.HidePrompt(Enum.KeyCode.Q)
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	if _stopCharacterObserver then
		_stopCharacterObserver()
		_stopCharacterObserver = nil
	end
	Local.UnbindActions()
end

return Shared