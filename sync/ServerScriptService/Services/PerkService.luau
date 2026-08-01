--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local DataService = require(script.Parent.DataService)
local Monetization = require(script.Parent.MonetizationService)
local PerksConfig = require(ReplicatedStorage.Modules.Configs.PerksConfig)
local Network = require(ReplicatedStorage.Modules.Network)

--|| Types
type Team = PerksConfig.Team

--|| Variables
local _networkConnections: { Network.Cleanup } = {}
local _dataConnections: { RBXScriptConnection } = {}

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_networkConnections, Network:BindEvent("Perks", "RequestEquip", function(player: Player, data: { team: Team?, itemName: string? })
		Local.HandleRequestEquip(player, data)
	end))

	table.insert(_dataConnections, DataService.OnDataLoaded:Connect(function(player: Player, playerData: DataService.PlayerData)
		Local.CheckWinUnlocks(player, playerData)
	end))

	table.insert(_dataConnections, DataService.OnDataChanged:Connect(function(player: Player, action, playerData: DataService.PlayerData)
		if action and action.type == "UpdateProfile" then
			Local.CheckWinUnlocks(player, playerData)
		end
	end))

	-- Sole handler on this channel game-wide (Channel:SetHandler warns/overwrites on a second
	-- caller) — if another purchase category needs DevProduct receipts later, dispatch by
	-- productId from inside this one handler rather than calling SetHandler again.
	Monetization.Channel.Manager:SetHandler(Monetization.Config.Channels.DevProduct, Local.HandleRobuxPurchase)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.HandleRequestEquip(player: Player, data: { team: Team?, itemName: string? })
	if not DataService.IsDataLoaded(player) then return end

	local team = data.team
	if team ~= "Smuggler" and team ~= "TSA" then return end

	if data.itemName == nil then
		DataService.UpdateData(player, { type = "SetLoadout", data = { team = team, itemName = nil } })
		Network:FireClient("Perks", player, "EquipResult", { success = true, team = team, itemName = nil })
		return
	end

	local entry = PerksConfig.GetEntry(data.itemName)
	if not entry or entry.team ~= team then
		Network:FireClient("Perks", player, "EquipResult", { success = false, reason = "Invalid perk", itemName = data.itemName })
		return
	end

	local playerData = DataService.GetData(player)
	if not playerData or not playerData.ownedItems[data.itemName] then
		Network:FireClient("Perks", player, "EquipResult", { success = false, reason = "Not unlocked", itemName = data.itemName })
		return
	end

	DataService.UpdateData(player, { type = "SetLoadout", data = { team = team, itemName = data.itemName } })
	Network:FireClient("Perks", player, "EquipResult", { success = true, team = team, itemName = data.itemName })
end

-- Auto-unlocks any perk whose win requirement is already met (checked on data load, covering
-- players who crossed a threshold before this system existed, and on every wins-related profile
-- update thereafter).
function Local.CheckWinUnlocks(player: Player, playerData: DataService.PlayerData)
	for _, entry in PerksConfig.Entries do
		if entry.winsRequired <= 0 or playerData.ownedItems[entry.itemName] then continue end

		local wins = if entry.team == "Smuggler" then playerData.profile.smugglerWins else playerData.profile.tsaWins
		if wins >= entry.winsRequired then
			DataService.UpdateData(player, { type = "AddOwnedItem", data = { itemName = entry.itemName } })
		end
	end
end

-- Award-channel handler for Config.Channels.DevProduct, invoked by MonetizationService once a
-- receipt is confirmed. No PerksConfig entry has a real robuxProductId yet, so this always
-- returns false (NotProcessedYet) until product IDs are created and filled in.
function Local.HandleRobuxPurchase(player: Player, productId: number): boolean
	local entry = PerksConfig.GetEntryByProductId(productId)
	if not entry then return false end

	if not DataService.IsDataLoaded(player) then return false end

	DataService.UpdateData(player, { type = "AddOwnedItem", data = { itemName = entry.itemName } })
	return true
end

-- [[ Public Functions ]] --

function Shared.Destroy()
	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	for _, conn in _dataConnections do
		conn:Disconnect()
	end
	table.clear(_dataConnections)
end

return Shared
