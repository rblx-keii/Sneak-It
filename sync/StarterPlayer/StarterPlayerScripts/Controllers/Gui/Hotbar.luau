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

local hotbar = inventoryUi.Frame
local inventoryPanel = hotbar.Inventory

local equippedFrame = inventoryPanel.Equipped
local equippedContent = equippedFrame.Content :: Frame
local equippedButton = equippedContent.Button :: TextButton
local equippedIcon = equippedContent.Icon :: ImageLabel
local equippedItemName = equippedContent.ItemName :: TextLabel

local perkFrame = hotbar.Perk
local perkWrapper = perkFrame.Content :: Frame
local perkContainer = perkWrapper.Container :: Frame
local perkButton = perkContainer.Button :: TextButton
local perkIcon = perkContainer.Icon :: ImageLabel
local perkItemName = perkContainer.ItemName :: TextLabel

local bagContentFrame = inventoryPanel.Content :: Frame
local bagTitle = bagContentFrame.Title :: TextLabel
local bagContainer = bagContentFrame.Container :: Frame
local bagLine = inventoryPanel.Line :: Frame

local bagSlots: { Frame } = {
	bagContainer.Slot1,
	bagContainer.Slot2,
	bagContainer.Slot3,
	bagContainer.Slot4,
	bagContainer.Slot5,
}

local arrowImage = hotbar.Arrow :: ImageLabel

local player = Players.LocalPlayer

--|| Types
type ItemSyncData = {
	name: string,
	weight: number,
	rating: number,
	isBag: boolean,
	uid: string,
	iconId: number?,
	maxWeight: number?,
}

type BagSlotData = {
	name: string,
	weight: number,
	rating: number,
	iconId: number?,
}

type BagGroupData = {
	name: string,
	iconId: number?,
	count: number,
}

type LoadoutSlot = "Perk" | "Inventory"

type SyncPayload = {
	action: "ItemPickup" | "ItemDropped" | "ItemThrown" | "BagStore" | "BagPop" | "ItemConsumed" | "ItemStashed",
	heldItem: ItemSyncData?,
	bagContents: { BagSlotData }?,
	perkItem: ItemSyncData?,
	inventoryItem: ItemSyncData?,
	activeSlot: LoadoutSlot?,
}

--|| Variables
local _networkConnections: { Network.Cleanup } = {}
local _slotSwapHandle: any = nil
local _equippedButtonConn: RBXScriptConnection? = nil
local _perkButtonConn: RBXScriptConnection? = nil

local _heldItem: ItemSyncData? = nil
local _perkItem: ItemSyncData? = nil
local _inventoryItem: ItemSyncData? = nil
local _activeSlot: LoadoutSlot? = nil
local _bagContents: { BagSlotData } = {}

local _hadInventoryItem: boolean = false
local _hadPerkItem: boolean = false
local _gridVisible: boolean = false

--|| Constants
local SLOT_SWAP_ACTION = "Hotbar_SlotSwap"
local SLOT_SWAP_KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.DPadUp, Enum.UserInputType.MouseWheel }

local ACTIVE_SLOT_TRANSPARENCY = 0.25
local INACTIVE_SLOT_TRANSPARENCY = 0.9

local TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSED_SLOT_SCALE = 0.001

-- Target geometry pulled from the Bag/Not Bag/Null reference states in gui-sync/Hotbar.model.json.
-- Inventory/Perk sit under a UIListLayout on Frame, so only their Size needs tweening; Equipped is
-- freely positioned inside Inventory, so it needs both Position and Size.
local INVENTORY_SIZE_NULL = UDim2.fromScale(0, 1)
local INVENTORY_SIZE_NOT_BAG = UDim2.fromScale(0.17738783359527588, 1)
local INVENTORY_SIZE_BAG = UDim2.fromScale(0.7293499708175659, 1)

local PERK_SIZE_NULL = UDim2.fromScale(0, 1)
local PERK_SIZE_SHOWN = UDim2.fromScale(0.17716999351978302, 1)

local EQUIPPED_POS_NOT_BAG = UDim2.fromScale(0.15412628650665283, 0.49414753913879395)
local EQUIPPED_SIZE_NOT_BAG = UDim2.fromScale(0.8979531526565552, 0.8748841285705566)
local EQUIPPED_POS_BAG = UDim2.fromScale(0.03852999955415726, 0.5)
local EQUIPPED_SIZE_BAG = UDim2.fromScale(0.21908000111579895, 0.8814799785614014)

local LINE_SIZE_HIDDEN = UDim2.fromScale(0.0014903086703270674, 0)
local LINE_SIZE_SHOWN = UDim2.fromScale(0.0014903086703270674, 0.888887345790863)

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Local.ApplyNullState()

	table.insert(_networkConnections, Network:BindEvent("Inventory", "Sync", Local.ApplySync))

	_equippedButtonConn = equippedButton.Activated:Connect(function()
		Local.RequestSwap("Inventory")
	end)

	_perkButtonConn = perkButton.Activated:Connect(function()
		Local.RequestSwap("Perk")
	end)

	table.insert(_networkConnections, RoundController.OnPlayingChanged:Connect(Local.SetInventoryEnabled))
	Local.SetInventoryEnabled(RoundController.IsPlaying())
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetInventoryEnabled(enabled: boolean)
	inventoryUi.Enabled = enabled

	if enabled then
		Local.BindSlotSwapControls()
	else
		Local.UnbindSlotSwapControls()
	end
end

function Local.GetScale(instance: GuiObject): UIScale
	local scale = instance:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = instance
	end
	return scale
end

-- Hides and collapses every sub frame under Frame so values can be set up before revealing.
function Local.ApplyNullState()
	inventoryPanel.Visible = false
	inventoryPanel.Size = INVENTORY_SIZE_NULL

	equippedFrame.Visible = false
	equippedFrame.Position = EQUIPPED_POS_NOT_BAG
	equippedFrame.Size = EQUIPPED_SIZE_NOT_BAG

	bagContentFrame.Visible = false
	bagLine.Visible = false
	bagLine.Size = LINE_SIZE_HIDDEN
	bagTitle.TextTransparency = 1

	for _, slot in bagSlots do
		slot.Visible = false
		Local.GetScale(slot).Scale = CLOSED_SLOT_SCALE
	end

	perkFrame.Visible = false
	perkFrame.Size = PERK_SIZE_NULL

	arrowImage.Visible = false
	Local.GetScale(arrowImage).Scale = CLOSED_SLOT_SCALE
end

function Local.PopulateItemSlot(itemNameLabel: TextLabel, icon: ImageLabel, data: ItemSyncData)
	itemNameLabel.Text = data.name
	icon.Image = if data.iconId then `rbxassetid://{data.iconId}` else ""
end

function Local.ClearItemSlot(itemNameLabel: TextLabel, icon: ImageLabel)
	itemNameLabel.Text = ""
	icon.Image = ""
end

function Local.RefreshHotbarSlotContent()
	if _inventoryItem then
		Local.PopulateItemSlot(equippedItemName, equippedIcon, _inventoryItem)
		equippedContent.BackgroundTransparency = if _activeSlot == "Inventory" then ACTIVE_SLOT_TRANSPARENCY else INACTIVE_SLOT_TRANSPARENCY
	else
		Local.ClearItemSlot(equippedItemName, equippedIcon)
	end

	if _perkItem then
		Local.PopulateItemSlot(perkItemName, perkIcon, _perkItem)
		perkContainer.BackgroundTransparency = if _activeSlot == "Perk" then ACTIVE_SLOT_TRANSPARENCY else INACTIVE_SLOT_TRANSPARENCY
	else
		Local.ClearItemSlot(perkItemName, perkIcon)
	end
end

function Local.GroupBagContents(contents: { BagSlotData }): { BagGroupData }
	local groups: { BagGroupData } = {}
	local index: { [string]: BagGroupData } = {}

	for _, entry in contents do
		local group = index[entry.name]
		if group then
			group.count += 1
		else
			group = { name = entry.name, iconId = entry.iconId, count = 1 }
			index[entry.name] = group
			table.insert(groups, group)
		end
	end

	return groups
end

function Local.RefreshBagSlots(groups: { BagGroupData })
	for i, slot in bagSlots do
		local group = groups[i]
		if not group then
			slot.Visible = false
			continue
		end

		local wasHidden = not slot.Visible
		slot.Visible = true

		local icon = slot:FindFirstChild("Icon") :: ImageLabel
		local itemName = slot:FindFirstChild("ItemName") :: TextLabel
		local itemCount = slot:FindFirstChild("ItemCount") :: TextLabel

		icon.Image = if group.iconId then `rbxassetid://{group.iconId}` else ""
		itemName.Text = group.name
		itemCount.Visible = group.count > 1
		itemCount.Text = `x{group.count}`

		-- A slot appearing while the grid is already open (2nd+ item in an open bag) needs its
		-- own pop-in tween here — UpdateInventoryVisual only replays when the grid's overall
		-- visibility flips, which won't happen for this case.
		if wasHidden then
			local scale = Local.GetScale(slot)
			scale.Scale = CLOSED_SLOT_SCALE
			TweenService:Create(scale, TWEEN_INFO, { Scale = 1 }):Play()
		end
	end

	local weightText = `{string.format("%.1f", (_heldItem and _heldItem.weight) or 0)}/{string.format("%.1f", (_heldItem and _heldItem.maxWeight) or 0)}`
	local hiddenCount = #groups - #bagSlots
	local hiddenText = if hiddenCount > 0 then ` ({hiddenCount} Hidden)` else ""

	bagTitle.Text = `BAG CONTENTS ({weightText}){hiddenText}`
end

function Local.ClearBagSlots()
	for _, slot in bagSlots do
		slot.Visible = false
	end
end

-- Tweens Inventory/Equipped/the bag grid to the size that matches (hasItem, gridVisible).
-- hardReset snaps everything back to the Null look first — used for a brand new pickup so the
-- "grow in" always starts clean; a bag's contents going 0 -> 1 skips it and morphs directly.
function Local.UpdateInventoryVisual(hasItem: boolean, gridVisible: boolean, hardReset: boolean)
	if hardReset then
		inventoryPanel.Size = INVENTORY_SIZE_NULL
		equippedFrame.Position = EQUIPPED_POS_NOT_BAG
		equippedFrame.Size = EQUIPPED_SIZE_NOT_BAG
		bagLine.Size = LINE_SIZE_HIDDEN
		bagTitle.TextTransparency = 1
		for _, slot in bagSlots do
			if slot.Visible then
				Local.GetScale(slot).Scale = CLOSED_SLOT_SCALE
			end
		end
	end

	if hasItem then
		inventoryPanel.Visible = true
		equippedFrame.Visible = true
	end

	if gridVisible then
		bagContentFrame.Visible = true
		bagLine.Visible = true
	end

	local targetInventorySize = if not hasItem then INVENTORY_SIZE_NULL elseif gridVisible then INVENTORY_SIZE_BAG else INVENTORY_SIZE_NOT_BAG
	local targetEquippedPos = if gridVisible then EQUIPPED_POS_BAG else EQUIPPED_POS_NOT_BAG
	local targetEquippedSize = if gridVisible then EQUIPPED_SIZE_BAG else EQUIPPED_SIZE_NOT_BAG

	TweenService:Create(inventoryPanel, TWEEN_INFO, { Size = targetInventorySize }):Play()
	TweenService:Create(equippedFrame, TWEEN_INFO, { Position = targetEquippedPos, Size = targetEquippedSize }):Play()
	TweenService:Create(bagLine, TWEEN_INFO, { Size = gridVisible and LINE_SIZE_SHOWN or LINE_SIZE_HIDDEN }):Play()
	TweenService:Create(bagTitle, TWEEN_INFO, { TextTransparency = gridVisible and 0 or 1 }):Play()

	for _, slot in bagSlots do
		TweenService:Create(Local.GetScale(slot), TWEEN_INFO, { Scale = gridVisible and 1 or CLOSED_SLOT_SCALE }):Play()
	end

	if not hasItem or not gridVisible then
		task.delay(TWEEN_INFO.Time, function()
			if _hadInventoryItem ~= hasItem or _gridVisible ~= gridVisible then return end

			if not gridVisible then
				bagContentFrame.Visible = false
				bagLine.Visible = false
			end

			if not hasItem then
				inventoryPanel.Visible = false
				equippedFrame.Visible = false
			end
		end)
	end
end

function Local.UpdatePerkVisual(hasPerk: boolean, hardReset: boolean)
	if hardReset then
		perkFrame.Size = PERK_SIZE_NULL
		Local.GetScale(arrowImage).Scale = CLOSED_SLOT_SCALE
	end

	if hasPerk then
		perkFrame.Visible = true
		arrowImage.Visible = true
	end

	TweenService:Create(perkFrame, TWEEN_INFO, { Size = hasPerk and PERK_SIZE_SHOWN or PERK_SIZE_NULL }):Play()
	TweenService:Create(Local.GetScale(arrowImage), TWEEN_INFO, { Scale = hasPerk and 1 or CLOSED_SLOT_SCALE }):Play()

	if not hasPerk then
		task.delay(TWEEN_INFO.Time, function()
			if _hadPerkItem then return end
			perkFrame.Visible = false
			arrowImage.Visible = false
		end)
	end
end

function Local.RequestSwap(slot: LoadoutSlot)
	if slot == _activeSlot then return end
	if slot == "Perk" and not _perkItem then return end
	if slot == "Inventory" and not _inventoryItem then return end

	Network:FireServer("Item", "RequestSwap", { slot = slot })
end

function Local.ToggleSlot()
	Local.RequestSwap(if _activeSlot == "Perk" then "Inventory" else "Perk")
end

function Local.BindSlotSwapControls()
	if _slotSwapHandle then return end

	_slotSwapHandle = InputController.BindAction({
		name = SLOT_SWAP_ACTION,
		keys = SLOT_SWAP_KEYS,
		priority = Enum.ContextActionPriority.Medium.Value,
		callback = function(_name: string, state: Enum.UserInputState, input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				if state ~= Enum.UserInputState.Change then return Enum.ContextActionResult.Pass end
				Local.ToggleSlot()
				return Enum.ContextActionResult.Sink
			end

			if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end

			if input.KeyCode == Enum.KeyCode.One then
				Local.RequestSwap("Inventory")
			elseif input.KeyCode == Enum.KeyCode.Two then
				Local.RequestSwap("Perk")
			elseif input.KeyCode == Enum.KeyCode.DPadUp then
				Local.ToggleSlot()
			else
				return Enum.ContextActionResult.Pass
			end

			return Enum.ContextActionResult.Sink
		end,
	})
end

function Local.UnbindSlotSwapControls()
	if _slotSwapHandle then
		_slotSwapHandle:Unbind()
		_slotSwapHandle = nil
	end
end

function Local.ApplySync(payload: SyncPayload)
	_heldItem = payload.heldItem or nil
	_bagContents = payload.bagContents or {}
	_perkItem = payload.perkItem or nil
	_inventoryItem = payload.inventoryItem or nil
	_activeSlot = payload.activeSlot or nil

	Local.RefreshHotbarSlotContent()

	local groups = Local.GroupBagContents(_bagContents)
	local isHoldingBag = _heldItem ~= nil and _heldItem.isBag
	local hasInventoryItem = _inventoryItem ~= nil
	local hasPerkItem = _perkItem ~= nil
	local gridVisible = isHoldingBag and #groups > 0

	if isHoldingBag then
		Local.RefreshBagSlots(groups)
	else
		Local.ClearBagSlots()
	end

	if hasInventoryItem ~= _hadInventoryItem or gridVisible ~= _gridVisible then
		local hardReset = hasInventoryItem and not _hadInventoryItem
		_hadInventoryItem = hasInventoryItem
		_gridVisible = gridVisible
		Local.UpdateInventoryVisual(hasInventoryItem, gridVisible, hardReset)
	end

	if hasPerkItem ~= _hadPerkItem then
		local hardReset = hasPerkItem
		_hadPerkItem = hasPerkItem
		Local.UpdatePerkVisual(hasPerkItem, hardReset)
	end
end

-- [[ Public Functions ]] --
function Shared.ToggleSlot()
	Local.ToggleSlot()
end

function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	if _equippedButtonConn then
		_equippedButtonConn:Disconnect()
		_equippedButtonConn = nil
	end

	if _perkButtonConn then
		_perkButtonConn:Disconnect()
		_perkButtonConn = nil
	end

	Local.UnbindSlotSwapControls()
	Local.ClearItemSlot(equippedItemName, equippedIcon)
	Local.ClearItemSlot(perkItemName, perkIcon)
	Local.ClearBagSlots()
end

return Shared
