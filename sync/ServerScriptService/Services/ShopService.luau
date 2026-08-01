--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local DataService = require(script.Parent.DataService)
local ShopConfig = require(ReplicatedStorage.Modules.Configs.ShopConfig)
local Network = require(ReplicatedStorage.Modules.Network)

--|| Variables
local _networkConnections: { Network.Cleanup } = {}

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Shop", "RequestPurchase", function(player: Player, data: { itemName: string? })
		Local.HandleRequestPurchase(player, data)
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.HandleRequestPurchase(player: Player, data: { itemName: string? })
	if not DataService.IsDataLoaded(player) then return end

	local itemName = data.itemName
	if typeof(itemName) ~= "string" or itemName == "" then return end

	local entry = ShopConfig.GetEntry(itemName)
	if not entry then
		Network:FireClient("Shop", player, "PurchaseResult", { success = false, reason = "Not for sale", itemName = itemName })
		return
	end

	local playerData = DataService.GetData(player)
	if not playerData then return end

	if playerData.stats.coins < entry.price then
		Network:FireClient("Shop", player, "PurchaseResult", { success = false, reason = "Insufficient coins", itemName = itemName })
		return
	end

	-- Consumables are stackable stock, not one-time unlocks — repeat purchases just add to the
	-- count (see loadout.consumables / InventoryService for how the stock gets equipped/spent).
	DataService.UpdateData(player, { type = "SpendCoins", data = { amount = entry.price } })
	DataService.UpdateData(player, { type = "AddItemStock", data = { itemName = itemName, amount = 1 } })

	Network:FireClient("Shop", player, "PurchaseResult", { success = true, itemName = itemName, price = entry.price })
end

function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared
