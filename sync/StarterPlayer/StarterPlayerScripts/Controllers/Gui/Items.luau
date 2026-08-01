--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ShopConfig = require(ReplicatedStorage.Modules.Configs.ShopConfig)
local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)
local GuiController = require(script.Parent.Parent.GuiController)
local DataController = require(script.Parent.Parent.DataController)

local Gui = GuiController.Guis.Items
local content = Gui.Frame.Content
local tabsFrame = content.Tabs
local itemsFrame = content.Container.items :: ScrollingFrame
local template = itemsFrame.Template :: Frame
template.Visible = false

--|| Types
type Category = "All" | ShopConfig.ShopCategory

--|| Variables
local _networkConnections: { Network.Cleanup } = {}
local _connections: { RBXScriptConnection } = {}
local _cards: { Frame } = {}
local _tabButtons: { [Category]: ImageButton } = {}
local _activeCategory: Category = "All"
local _ownedItems: { [string]: boolean } = {}
local _coins: number = 0

--|| Constants
local TAB_ACTIVE_TRANSPARENCY = 0
local TAB_INACTIVE_TRANSPARENCY = 0.5
local AFFORDABLE_COLOR = Color3.fromRGB(0, 27, 72)
local UNAFFORDABLE_COLOR = Color3.fromRGB(180, 40, 40)

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	for _, tabFrame in tabsFrame:GetChildren() do
		if not tabFrame:IsA("Frame") then continue end

		local title = tabFrame:FindFirstChild("title") :: TextLabel
		local tab = tabFrame:FindFirstChild("tab") :: ImageButton
		if not title or not tab then continue end

		local category = title.Text :: Category
		_tabButtons[category] = tab

		table.insert(_connections, tab.Activated:Connect(function()
			Local.SetActiveCategory(category)
		end))
	end

	table.insert(_networkConnections, Network:BindEvent("Shop", "PurchaseResult", function(result: { success: boolean, reason: string? })
		if not result.success then
			warn("[Items] Purchase failed:", result.reason)
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
function Local.ApplyData(data: DataController.PlayerData)
	_ownedItems = data.ownedItems
	_coins = data.stats.coins
	Local.RefreshItems()
end

function Local.SetActiveCategory(category: Category)
	_activeCategory = category

	for cat, tab in _tabButtons do
		tab.ImageTransparency = if cat == category then TAB_ACTIVE_TRANSPARENCY else TAB_INACTIVE_TRANSPARENCY
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
		Local.CreateCard(entry)
	end
end

function Local.CreateCard(entry: ShopConfig.ShopEntry)
	local card = template:Clone()
	card.Visible = true

	local cardContent = card:FindFirstChild("Content") :: Frame
	local itemName = cardContent:FindFirstChild("ItemName") :: TextLabel
	local description = cardContent:FindFirstChild("Description") :: TextLabel
	local purchase = cardContent:FindFirstChild("Purchase") :: Frame
	local purchaseButton = purchase:FindFirstChild("Button") :: TextButton
	local purchaseLabel = purchase:FindFirstChild("Label") :: TextLabel
	local priceLabel = cardContent:FindFirstChild("Price").Label :: TextLabel
	local icon = card:FindFirstChild("Icon") :: ImageLabel?

	card.Name = entry.displayName
	itemName.Text = entry.displayName
	description.Text = entry.description
	priceLabel.Text = tostring(entry.price)

	if icon then
		local itemModule = ItemsConfig.GetItem(entry.itemName)
		local iconId = itemModule and itemModule.properties.iconId
		icon.Image = if iconId then `rbxassetid://{iconId}` else ""
	end

	local owned = _ownedItems[entry.itemName] == true
	purchaseLabel.Text = if owned then "OWNED" else "BUY"
	priceLabel.TextColor3 = if owned or _coins >= entry.price then AFFORDABLE_COLOR else UNAFFORDABLE_COLOR

	table.insert(_connections, purchaseButton.Activated:Connect(function()
		if _ownedItems[entry.itemName] then return end
		Network:FireServer("Shop", "RequestPurchase", { itemName = entry.itemName })
	end))

	card.Parent = itemsFrame
	table.insert(_cards, card)
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
