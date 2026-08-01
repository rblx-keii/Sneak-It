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
	table.insert(_networkConnections, Network:BindEvent("Inventory", "RequestSetLoadout", function(player: Player, data: { itemNames: { string }? })
		Local.HandleRequestSetLoadout(player, data)
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --

-- 3 unique consumables if the Smuggler perk slot has DuffleBag equipped, 1 otherwise — TSA has no
-- equivalent perk, so it's always capped at 1. Mirrors UpdateData's SetConsumableLoadout assert.
function Local.GetConsumableCap(playerData: DataService.PlayerData): number
	return if playerData.loadout.Smuggler == "DuffleBag" then 3 else 1
end

function Local.HandleRequestSetLoadout(player: Player, data: { itemNames: { string }? })
	if not DataService.IsDataLoaded(player) then return end

	local itemNames = data.itemNames
	if typeof(itemNames) ~= "table" then return end

	local playerData = DataService.GetData(player)
	if not playerData then return end

	local cap = Local.GetConsumableCap(playerData)
	if #itemNames > cap then
		Network:FireClient("Inventory", player, "SetLoadoutResult", { success = false, reason = "Exceeds equip cap" })
		return
	end

	local seen: { [string]: boolean } = {}
	for _, itemName in itemNames do
		if typeof(itemName) ~= "string" or itemName == "" or seen[itemName] then
			Network:FireClient("Inventory", player, "SetLoadoutResult", { success = false, reason = "Invalid selection" })
			return
		end
		if not ShopConfig.GetEntry(itemName) then
			Network:FireClient("Inventory", player, "SetLoadoutResult", { success = false, reason = "Not a consumable" })
			return
		end
		if (playerData.itemStock[itemName] or 0) <= 0 then
			Network:FireClient("Inventory", player, "SetLoadoutResult", { success = false, reason = "Not in stock" })
			return
		end
		seen[itemName] = true
	end

	DataService.UpdateData(player, { type = "SetConsumableLoadout", data = { itemNames = itemNames } })
	Network:FireClient("Inventory", player, "SetLoadoutResult", { success = true, itemNames = itemNames })
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)
end

return Shared
