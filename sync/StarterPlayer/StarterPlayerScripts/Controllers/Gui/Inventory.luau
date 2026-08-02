--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ShopConfig = require(ReplicatedStorage.Modules.Configs.ShopConfig)
local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)
local GuiController = require(script.Parent.Parent.GuiController)
local DataController = require(script.Parent.Parent.DataController)

local Gui = GuiController.Guis.Inventory
local content = Gui.Frame.Content
local tabsFrame = content.Tabs
local itemsFrame = content.Container.Items :: ScrollingFrame
local template = itemsFrame.Template :: Frame
template.Visible = false

-- Script-built placeholder; swap for a dedicated Studio element once the UI dev has time.
local emptyLabel = Instance.new("TextLabel")
emptyLabel.Name = "EmptyState"
emptyLabel.BackgroundTransparency = 1
emptyLabel.Size = UDim2.fromScale(1, 1)
emptyLabel.TextWrapped = true
emptyLabel.TextScaled = true
emptyLabel.FontFace = Font.new("rbxassetid://11702779517", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
emptyLabel.TextColor3 = Color3.fromRGB(0, 27, 72)
emptyLabel.Text = "You don't own any items yet — visit the Shop next round to stock up!"
emptyLabel.Visible = false
emptyLabel.Parent = itemsFrame

--|| Types
type Category = "All" | ShopConfig.ShopCategory

--|| Variables
local _networkConnections: { Network.Cleanup } = {}
local _connections: { RBXScriptConnection } = {}
local _cards: { Frame } = {}
local _tabButtons: { [Category]: ImageButton } = {}
local _activeCategory: Category = "All"
local _itemStock: { [string]: number } = {}
local _selected: { [string]: boolean } = {}
local _loadoutSmuggler: string? = nil

--|| Constants
local TAB_ACTIVE_TRANSPARENCY = 0
local TAB_INACTIVE_TRANSPARENCY = 0.5
local DEFAULT_COLOR = Color3.new(1, 1, 1)
local SELECTED_COLOR = Color3.fromRGB(200, 255, 210)

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	for _, tabFrame in tabsFrame:GetChildren() do
		if not tabFrame:IsA("Frame") then continue end

		local button = tabFrame:FindFirstChild("Button") :: ImageButton?
		if not button then continue end

		local category = tabFrame.Name :: Category
		_tabButtons[category] = button

		table.insert(_connections, button.Activated:Connect(function()
			Local.SetActiveCategory(category)
		end))
	end

	table.insert(_networkConnections, Network:BindEvent("Inventory", "SetLoadoutResult", function(result: { success: boolean, reason: string? })
		if not result.success then
			warn("[Inventory] SetLoadout failed:", result.reason)
		end
	end))

	table.insert(_connections, DataController.OnDataChanged:Connect(function(_action, data: DataController.PlayerData)
		Local.ApplyData(data)
	end))

	Local.SetActiveCategory("All")
end

function Shared.Start()
	task.spawn(function()
		Local.ApplyData(DataController.GetData())
	end)
end

-- [[ Private Functions ]] --

-- 3 unique items if the Smuggler perk slot has DuffleBag equipped, 1 otherwise — mirrors
-- InventoryService/UpdateData's server-authoritative cap, used here only for instant client
-- feedback (the server re-validates on every RequestSetLoadout).
function Local.GetConsumableCap(): number
	return if _loadoutSmuggler == "DuffleBag" then 3 else 1
end

function Local.ApplyData(data: DataController.PlayerData)
	_itemStock = data.itemStock or {}
	_loadoutSmuggler = data.loadout.Smuggler

	_selected = {}
	for _, itemName in data.loadout.consumables or {} do
		_selected[itemName] = true
	end

	Local.RefreshItems()
end

function Local.SetActiveCategory(category: Category)
	_activeCategory = category

	for cat, button in _tabButtons do
		button.ImageTransparency = if cat == category then TAB_ACTIVE_TRANSPARENCY else TAB_INACTIVE_TRANSPARENCY
	end

	Local.RefreshItems()
end

function Local.ClearCards()
	for _, card in _cards do
		card:Destroy()
	end
	table.clear(_cards)
end

function Local.RefreshItems()
	Local.ClearCards()

	local entries = if _activeCategory == "All"
		then ShopConfig.Entries
		else ShopConfig.GetCategoryEntries(_activeCategory :: ShopConfig.ShopCategory)

	for _, entry in entries do
		local stock = _itemStock[entry.itemName] or 0
		if stock > 0 then
			Local.CreateCard(entry, stock)
		end
	end

	emptyLabel.Visible = _activeCategory == "All" and #_cards == 0
end

function Local.CreateCard(entry: ShopConfig.ShopEntry, stock: number)
	local card = template:Clone()
	card.Visible = true

	local itemLabel = card:FindFirstChild("Item") :: TextLabel
	local countLabel = card:FindFirstChild("Count") :: TextLabel
	local icon = card:FindFirstChild("Icon") :: ImageLabel?
	local button = card:FindFirstChild("Button") :: TextButton

	card.Name = entry.displayName
	itemLabel.Text = entry.displayName
	countLabel.Text = `x{stock}`
	card.BackgroundColor3 = if _selected[entry.itemName] then SELECTED_COLOR else DEFAULT_COLOR

	if icon then
		local itemModule = ItemsConfig.GetItem(entry.itemName)
		local iconId = itemModule and itemModule.properties.iconId
		icon.Image = if iconId then `rbxassetid://{iconId}` else ""
	end

	table.insert(_connections, button.Activated:Connect(function()
		Local.ToggleSelected(entry.itemName)
	end))

	card.Parent = itemsFrame
	table.insert(_cards, card)
end

function Local.ToggleSelected(itemName: string)
	local nextSelection = {}

	if _selected[itemName] then
		for name in _selected do
			if name ~= itemName then table.insert(nextSelection, name) end
		end
	else
		local count = 0
		for _ in _selected do count += 1 end
		if count >= Local.GetConsumableCap() then return end

		for name in _selected do table.insert(nextSelection, name) end
		table.insert(nextSelection, itemName)
	end

	Network:FireServer("Inventory", "RequestSetLoadout", { itemNames = nextSelection })
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	Local.ClearCards()
end

return Shared
