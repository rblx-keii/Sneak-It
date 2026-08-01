--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local InputController = require(ReplicatedStorage.Modules.Shared.InputController)

local GuiController = require(script.Parent.Parent.GuiController)
local RoundController = require(script.Parent.Parent.RoundController)
local inventoryUi = GuiController.Guis.Hotbar

local hotbar = inventoryUi.Hotbar
local slot1 = hotbar.Slot1
local slot1Content = slot1.Content

local arrowFrame = hotbar.Arrow
local arrowContent = arrowFrame.Content
local arrowImage = arrowContent.ImageLabel
local arrowButton = arrowContent.Button

local bagPanel = inventoryUi.BagContent
local bagContentFrame = bagPanel.Content
local bagTemplate = bagContentFrame.Template

local player = Players.LocalPlayer

--|| Types
type ItemSyncData = {
	name: string,
	weight: number,
	rating: number,
	isBag: boolean,
	uid: string,
}

type BagSlotData = {
	name: string,
	weight: number,
	rating: number,
}

type SyncPayload = {
	action: "ItemPickup" | "ItemDropped" | "ItemThrown" | "BagStore" | "BagPop" | "ItemConsumed",
	heldItem: ItemSyncData?,
	bagContents: { BagSlotData }?,
}

--|| Variables
local _networkConnections: { Network.Cleanup } = {}
local _bagToggleHandle: any = nil
local _arrowButtonConn: RBXScriptConnection? = nil

local _heldItem: ItemSyncData? = nil
local _bagContents: { BagSlotData } = {}
local _isBagOpen: boolean = false

--|| Constants
local BAG_TOGGLE_ACTION = "Inventory_ToggleBag"
local BAG_TOGGLE_KEYS = { Enum.KeyCode.B, Enum.KeyCode.DPadDown }

local TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local BAG_OPEN_POS = UDim2.new(0.5, 0, 0.5, 0)
local BAG_CLOSE_POS = UDim2.new(0.5, 0, 1.5, 0)

local FULL_STAR = "rbxassetid://103313807540511"
local EMPTY_STAR = "rbxassetid://130804386846291"
local HALF_STAR = "rbxassetid://123385895224097"

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	bagTemplate.Visible = false
	slot1.Visible = false
	bagPanel.Visible = false
	arrowFrame.Visible = false

	table.insert(_networkConnections, Network:BindEvent("Inventory", "Sync", function(payload: SyncPayload)
		Local.ApplySync(payload)

		arrowFrame.Visible = payload and payload.heldItem and payload.heldItem.isBag
	end))

	table.insert(_networkConnections, RoundController.OnPlayingChanged:Connect(Local.SetInventoryEnabled))
	Local.SetInventoryEnabled(RoundController.IsPlaying())
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetInventoryEnabled(enabled: boolean)
	inventoryUi.Enabled = enabled

	if not enabled and _isBagOpen then
		Local.SetBagPanelVisible(false)
	end
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

	for i = 1, 5 do
		local star = template:Clone()
		star.Name = `Star_{i}`
		star.Visible = true
		star.LayoutOrder = i

		if i <= math.floor(rating) then
			star.Image = FULL_STAR
		elseif i == math.ceil(rating) and rating % 1 >= 0.5 then
			star.Image = HALF_STAR
		else
			star.Image = EMPTY_STAR
		end

		star.Parent = ratingFrame
	end
end

function Local.PopulateSlot(content: Frame, data: BagSlotData)
	local itemName = content:FindFirstChild("ItemName") :: TextLabel
	local weight = content:FindFirstChild("Weight") :: TextLabel
	local rating = content:FindFirstChild("Rating") :: Frame

	if itemName then itemName.Text = data.name end
	if weight then weight.Text = `{data.weight} kg` end
	if rating then Local.PopulateStars(rating, data.rating) end
end

function Local.RefreshHeldSlot()
	if not _heldItem then
		Local.ClearHeldSlot()
		return
	end

	Local.PopulateSlot(slot1Content, _heldItem)
	slot1.Visible = true
end

function Local.ClearHeldSlot()
	slot1.Visible = false

	local itemName = slot1Content:FindFirstChild("ItemName") :: TextLabel
	local weight = slot1Content:FindFirstChild("Weight") :: TextLabel
	local rating = slot1Content:FindFirstChild("Rating") :: Frame

	if itemName then itemName.Text = "" end
	if weight then weight.Text = "" end
	if rating then
		for _, child in rating:GetChildren() do
			if child.Name ~= "Template" and child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
end

function Local.RefreshBagSlots()
	Local.ClearBagSlots()

	local emptyLabel = bagContentFrame:FindFirstChild("Empty")
	if emptyLabel then
		emptyLabel.Visible = #_bagContents == 0
	end

	for _, slotData in _bagContents do
		local clone = bagTemplate:Clone()
		clone.Visible = true

		local content = clone:FindFirstChild("Content")
		if content then
			Local.PopulateSlot(content, slotData)
		end

		clone.Parent = bagContentFrame
	end
end

function Local.ClearBagSlots()
	for _, child in bagContentFrame:GetChildren() do
		if child ~= bagTemplate and child:IsA("Frame") then
			child:Destroy()
		end
	end
end

function Local.SetBagPanelVisible(visible: boolean)
	if visible == _isBagOpen then return end
	_isBagOpen = visible

	bagPanel.Visible = true

	local tween = TweenService:Create(bagContentFrame, TWEEN_INFO, {
		Position = visible and BAG_OPEN_POS or BAG_CLOSE_POS
	})

	local arrowTween = TweenService:Create(
		hotbar.Arrow.Content.ImageLabel,
		TWEEN_INFO,
		{ Rotation = visible and -90 or 90 }
	)

	tween:Play()
	arrowTween:Play()

	if visible then
		task.defer(function()
			tween.Completed:Wait()
			bagPanel.ClipsDescendants = false
		end)
	else
		bagPanel.ClipsDescendants = true
		tween.Completed:Once(function()
			bagPanel.Visible = false
		end)
	end
end

function Local.ToggleBag()
	if not _heldItem or not _heldItem.isBag then return end
	Local.SetBagPanelVisible(not _isBagOpen)
end

function Local.BindBagControls()
	if _bagToggleHandle then return end

	_bagToggleHandle = InputController.BindAction({
		name = BAG_TOGGLE_ACTION,
		keys = BAG_TOGGLE_KEYS,
		priority = Enum.ContextActionPriority.Medium.Value,
		callback = function(_name: string, state: Enum.UserInputState, _input: InputObject)
			if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
			Local.ToggleBag()
			return Enum.ContextActionResult.Sink
		end,
	})

	_arrowButtonConn = arrowButton.Activated:Connect(Local.ToggleBag)
end

function Local.UnbindBagControls()
	if _bagToggleHandle then
		_bagToggleHandle:Unbind()
		_bagToggleHandle = nil
	end

	if _arrowButtonConn then
		_arrowButtonConn:Disconnect()
		_arrowButtonConn = nil
	end
end

function Local.ApplySync(payload: SyncPayload)
	_heldItem = payload.heldItem or nil
	_bagContents = payload.bagContents or {}

	Local.RefreshHeldSlot()

	local holdingBag = _heldItem ~= nil and _heldItem.isBag

	if holdingBag then
		Local.RefreshBagSlots()
		Local.BindBagControls()
	else
		if _isBagOpen then
			Local.SetBagPanelVisible(false)
		end
		Local.ClearBagSlots()
		Local.UnbindBagControls()
	end
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	Local.UnbindBagControls()
	Local.ClearHeldSlot()
	Local.ClearBagSlots()

	if _isBagOpen then
		Local.SetBagPanelVisible(false)
	end
end

return Shared