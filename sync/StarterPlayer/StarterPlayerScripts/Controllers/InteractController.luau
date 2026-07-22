--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local InputController = require(ReplicatedStorage.Modules.Shared.InputController)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)
local UtilsLibrary = require(ReplicatedStorage.Modules.Utils.UtilsLibrary)

local ActionPromptController = require(script.Parent.Gui.ActionPrompt)
local CameraController = require(script.Parent.CameraController)
local GuiController = require(script.Parent.GuiController)
local RoundController = require(script.Parent.RoundController)

local statsTemplate = ReplicatedStorage.Assets.ItemStats

local player = Players.LocalPlayer

--|| Types
type ItemData = {
	name: string,
	weight: number,
	rating: number,
}

--|| Variables
local _stopCharacterObserver: (() -> ())? = nil
local _interactHandle: any = nil
local _renderConn: RBXScriptConnection? = nil
local _playingConn: any = nil

local _currentTarget: Model? = nil
local _activeHighlight: Highlight? = nil
local _activeStatsUI: BillboardGui? = nil
local _isEquipped: boolean = false

--|| Constants
local MAX_INTERACT_DISTANCE = 15
local INTERACTABLE_TAG = "Interactable"

local INTERACT_ACTION = "Item_Interact"
local INTERACT_INPUT = Enum.KeyCode.E

local FULL_STAR = "rbxassetid://103313807540511"
local EMPTY_STAR = "rbxassetid://130804386846291"
local HALF_STAR = "rbxassetid://123385895224097"

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	_renderConn = RunService.RenderStepped:Connect(Local.OnRenderStepped)

	_playingConn = RoundController.OnPlayingChanged:Connect(function(isPlaying: boolean)
		if not isPlaying then
			Local.OnTargetExited()
		end
	end)

	_interactHandle = InputController.BindAction({
		name = INTERACT_ACTION,
		keys = { INTERACT_INPUT },
		priority = Enum.ContextActionPriority.High.Value,
		callback = Local.OnInteractInput
	})

	_stopCharacterObserver = Observers.observeLocalCharacter(function(character: Model)

		local stopAttribute = Observers.observeAttribute(character, "HeldItem", function(heldItemName)
			_isEquipped = (heldItemName ~= nil and heldItemName ~= "")

			if _currentTarget then
				local actionText = "Pick up Item"
				if _isEquipped then
					local heldItem = character:FindFirstChild(heldItemName)
					if heldItem and heldItem:GetAttribute("IsBag") then
						actionText = "Store in Bag"
					else
						actionText = "Swap Item"
					end
				end

				ActionPromptController.ChangeActionText(Enum.KeyCode.E, actionText)
			end
		end)

		return function()
			stopAttribute()
			_isEquipped = false
		end
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.OnInteractInput(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	if not RoundController.IsPlaying() then return Enum.ContextActionResult.Pass end
	if not _currentTarget then return Enum.ContextActionResult.Pass end

	local camera = workspace.CurrentCamera
	if not camera then return Enum.ContextActionResult.Pass end

	local cf = camera.CFrame
	Network:FireServer("Item", "RequestPickup", {
		item = _currentTarget,
		origin = Network.Obfuscator.Encode({ cf.X, cf.Y, cf.Z })
	})

	Local.OnTargetExited()
	return Enum.ContextActionResult.Sink
end

function Local.OnRenderStepped()
	if not RoundController.IsPlaying() then
		if _currentTarget then Local.OnTargetExited() end
		return
	end

	local character = player.Character
	if not character then
		if _currentTarget then Local.OnTargetExited() end
		return
	end

	local result = CameraController.GetLookTarget(MAX_INTERACT_DISTANCE)

	local newTarget: Model? = nil
	if result then
		newTarget = Local.GetInteractableFromResult(result)
	end

	if newTarget == _currentTarget then return end

	-- Target changed
	if _currentTarget then
		Local.OnTargetExited()
	end

	if newTarget then
		Local.OnTargetEntered(newTarget)
	end
end

function Local.GetInteractableFromResult(result: RaycastResult): Model?
	local instance = result.Instance
	local ancestor = instance

	while ancestor do
		if ancestor:IsA("Model") and CollectionService:HasTag(ancestor, INTERACTABLE_TAG) then
			return ancestor :: Model
		elseif ancestor:IsA("BasePart") and CollectionService:HasTag(ancestor, INTERACTABLE_TAG) then
			return ancestor :: any 
		end
		ancestor = ancestor.Parent
	end

	return nil
end

function Local.OnTargetEntered(model: Model)
	_currentTarget = model
	_activeHighlight = Local.CreateHighlight(model)
	_activeStatsUI = Local.CreateStatsUI(model)

	local actionText = "Pick up Item"
	if _isEquipped then
		local character = player.Character
		local heldItemName = character and character:GetAttribute("HeldItem")
		local heldItem = heldItemName and character:FindFirstChild(heldItemName)

		if heldItem and heldItem:GetAttribute("IsBag") then
			actionText = "Store in Bag"
		else
			actionText = "Swap Item"
		end
	end

	ActionPromptController.ShowPrompt(Enum.KeyCode.E, actionText)
end

function Local.OnTargetExited()
	if _activeHighlight then
		_activeHighlight:Destroy()
		_activeHighlight = nil
	end

	if _activeStatsUI then
		_activeStatsUI:Destroy()
		_activeStatsUI = nil
	end

	_currentTarget = nil

	ActionPromptController.HidePrompt(Enum.KeyCode.E)
end

function Local.CreateHighlight(target: Instance): Highlight
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineTransparency = 0
	highlight.Adornee = target :: PVInstance
	highlight.Parent = target
	return highlight
end

function Local.GetItemData(target: Instance): ItemData
	return {
		name = target:GetAttribute("ItemName") or target.Name or "Unknown Item",
		weight = target:GetAttribute("Weight") or 1.0,
		rating = target:GetAttribute("Rating") or 1,
	}
end

function Local.CreateStatsUI(target: Instance): BillboardGui
	local data = Local.GetItemData(target)

	local ui = statsTemplate:Clone()

	-- Populate labels
	local itemNameLabel = ui:FindFirstChild("ItemName") :: TextLabel
	local weightLabel = ui:FindFirstChild("Weight") :: TextLabel
	local ratingFrame = ui:FindFirstChild("Rating") :: Frame

	if itemNameLabel then
		itemNameLabel.Text = `{data.name}`
	end

	if weightLabel then
		weightLabel.Text = `{UtilsLibrary.formatUtils.Number.Round(data.weight, 2)} kg`
	end

	if ratingFrame then
		Local.PopulateStars(ratingFrame, data.rating)
	end

	ui.Adornee = target :: PVInstance
	ui.Parent = player:WaitForChild("PlayerGui")

	return ui
end

function Local.PopulateStars(ratingFrame: Frame, rating: number)
	local template = ratingFrame:FindFirstChild("Template") :: ImageLabel
	if not template then return end

	for _, child in ratingFrame:GetChildren() do
		if child.Name ~= "Template" and child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	template.Visible = false

	local roundedRating = math.round(rating)

	for i = 1, 5 do
		local star = template:Clone()
		star.Name = `Star_{i}`
		star.Visible = true
		star.LayoutOrder = i

		if HALF_STAR ~= nil then
			if i <= math.floor(rating) then
				star.Image = FULL_STAR
			elseif i == math.ceil(rating) and rating % 1 >= 0.5 then
				star.Image = HALF_STAR
			else
				star.Image = EMPTY_STAR
			end
		else
			star.Image = i <= roundedRating and FULL_STAR or EMPTY_STAR
		end

		star.Parent = ratingFrame
	end
end

-- [[ Public Functions ]] --
function Shared.GetCurrentTarget(): Model?
	return _currentTarget
end

function Shared.Destroy()
	if _stopCharacterObserver then
		_stopCharacterObserver()
		_stopCharacterObserver = nil
	end

	if _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end

	if _playingConn then
		_playingConn:Disconnect()
		_playingConn = nil
	end

	if _interactHandle then
		_interactHandle:Unbind()
		_interactHandle = nil
	end

	Local.OnTargetExited()
end

return Shared