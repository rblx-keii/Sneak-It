--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)

local JailService = require(script.Parent.JailService)
local RagdollService = require(script.Parent.RagdollService)
local RoundService = require(script.Parent.RoundService)
local DataService = require(script.Parent.DataService)

local DebrisFolder = ReplicatedStorage:FindFirstChild("Debris") or ReplicatedStorage
local _assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
local ItemTemplatesFolder = _assetsFolder and _assetsFolder:FindFirstChild("Items")

local _workspaceDebrisFolder = Workspace:FindFirstChild("Debris")
local ItemSpawnFolder = (_workspaceDebrisFolder and _workspaceDebrisFolder:FindFirstChild("Items")) or _workspaceDebrisFolder or Workspace

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _connections: {RBXScriptConnection} = {}
local _stopTagObserver: (() -> ())? = nil
local _bagContents: { [string]: { BagEntry } } = {}

local _activeThrowListeners: { [Model]: () -> () } = {}

-- Dual perk/inventory hotbar slots. Only ever populated for non-bag perks — a bag perk just is the
-- Inventory item (per design), so those players never get an entry here and never see a swap.
local _loadoutSlots: { [Player]: LoadoutSlots } = {}

-- True once a player has legitimately spent their single-use Perk this round (Shared.UseItem ->
-- ConsumeEquipped while it was active) — GrantPerkItem must not refund it, only recover it if it was
-- lost involuntarily (dropped on arrest).
local _perkConsumed: { [Player]: boolean } = {}

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

type BagEntry = {
	itemName: string,
	uid: string,
}

type SlotData = {
	itemName: string,
	uid: string,
}

type LoadoutSlots = {
	Perk: SlotData?,
	Inventory: SlotData?,
}

export type LoadoutSlot = "Perk" | "Inventory"

type SyncPayload = {
	action: "ItemPickup" | "ItemDropped" | "ItemThrown" | "BagStore" | "BagPop" | "ItemConsumed" | "ItemStashed",
	heldItem: ItemSyncData?,
	bagContents: { BagSlotData }?,
	perkItem: ItemSyncData?,
	inventoryItem: ItemSyncData?,
	activeSlot: LoadoutSlot?,
}

--|| Constants
local MAX_PICKUP_DISTANCE = 20
local THROW_FORCE = 80
local DROP_FORCE = 15
local INTERACT_TAG = "Interactable"
local ITEMBASEPART_TAG = "ItemBasePart"

local MIN_THROW_DOT_PRODUCT = 0.2
local RAGDOLL_THROW_WEIGHT = 1
local RAGDOLL_IMPACT_FORCE_MULTIPLIER = 8
local RAGDOLL_LISTEN_TIMEOUT = 5

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude

local SPAWN_DROP_HEIGHT = 5 -- studs above the target CFrame the surface blockcast starts from
local SPAWN_MAX_DROP = 50 -- studs the blockcast searches downward before giving up
local SPAWN_CAST_THICKNESS = 0.2 -- studs; kept thin since only the footprint (X/Z) needs to match the item

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Signals ]] --
Shared.OnItemEquipped = ModuleUtils.signal.new()

-- [[ Startup ]] --
function Shared.Init()
	_stopTagObserver = Observers.observeTag(INTERACT_TAG, Local.InitializeItem)

	table.insert(_networkConnections, Network:BindEvent("Item", "RequestPickup", function(player: Player, data: { item: Model, origin: string })
		local record = JailService.GetRecord(player)
		if not record or record.isJailed then return end

		local decoded = Network.Obfuscator.Decode(data.origin)
		if not decoded or #decoded < 3 then return end

		local originCFrame = CFrame.new(decoded[1], decoded[2], decoded[3])
		Shared.PickupItem(player, data.item, originCFrame)
	end))

	table.insert(_networkConnections, Network:BindEvent("Item", "RequestThrow", function(player: Player, data: { origin: CFrame, direction: Vector3 })
		local record = JailService.GetRecord(player)
		if not record or record.isJailed then return end

		Shared.ThrowItem(player, data.origin, data.direction)
	end))

	table.insert(_networkConnections, Network:BindEvent("Item", "RequestDrop", function(player: Player, _data: any)
		Shared.DropItem(player)
	end))

	table.insert(_networkConnections, Network:BindEvent("Item", "RequestPop", function(player: Player, _data: any)
		Shared.PopBagItem(player)
	end))

	table.insert(_networkConnections, Network:BindEvent("Item", "RequestUse", function(player: Player, data: { origin: CFrame?, direction: Vector3? })
		local originCFrame, direction = nil, nil

		if data and data.origin and data.direction then
			originCFrame = data.origin
			direction = data.direction
		end

		Shared.UseItem(player, originCFrame, direction)
	end))

	table.insert(_networkConnections, Network:BindEvent("Item", "RequestSwap", function(player: Player, data: { slot: LoadoutSlot })
		if data.slot ~= "Perk" and data.slot ~= "Inventory" then return end
		Shared.SetActiveSlot(player, data.slot)
	end))

	table.insert(_connections, Players.PlayerRemoving:Connect(function(player: Player)
		_loadoutSlots[player] = nil
		_perkConsumed[player] = nil
	end))

	JailService.OnJailed:Connect(function(player: Player)
		local character = player.Character
		if not character then return end
		Local.ClearEquipped(character)
	end)

	JailService.OnReleased:Connect(Shared.GrantPerkItem)

	-- Granted on InProgress, not Starting — Starting is the barricade-locked prep window.
	RoundService.OnStateChange:Connect(function(newState: RoundService.RoundState)
		if newState ~= "InProgress" then return end

		for _, player in RoundService.GetMatchParticipants() do
			local team = player.Team
			if team then
				Shared.GrantLoadout(player, team.Name)
			end
		end
	end)

	-- Mid-round late joiners skip the InProgress transition above, so they need their own grant.
	RoundService.OnPlayerJoinedMatch:Connect(Shared.GrantLoadout)

	-- OnRagdolled (not OnPlayerRagdolled) so a held item drops for NPCs too, not just players —
	-- ClearEquipped already no-ops the player-only network sync internally when there isn't one.
	RagdollService.OnRagdolled:Connect(function(rig: Model)
		Local.ClearEquipped(rig)
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --

function Local.IsBagItem(itemName: string): boolean
	local itemConfig = ItemsConfig.GetItem(itemName)
	return itemConfig ~= nil and itemConfig.attributes.IsBag == true
end

function Local.GetItemIconId(itemName: string): number?
	local itemConfig = ItemsConfig.GetItem(itemName)
	return itemConfig and itemConfig.properties.iconId
end

-- Equips `item` as the new HeldItem with no regard for whatever was held before — callers are
-- responsible for clearing/stashing the previous item first.
function Local.EquipItemDirect(player: Player, character: Model, item: Model)
	Local.EnsureUID(item)
	character:SetAttribute("HeldItem", item.Name)
	Local.WeldToHand(character, item)

	-- Swapped here server-side so Handle_Motor exists before HeldItem even replicates to the client
	if not Local.SwapGripWeldToMotor(item) then
		warn(`[ItemService] EquipItemDirect({player.Name}, {item.Name}) — Motor6D swap failed, item will stay weld-only`)
	end

	Local.RecalculateContraband(character)
	Local.SyncClient(player, "ItemPickup")

	Shared.OnItemEquipped:Fire(player, character, item)
end

-- Captures the currently-held item's identity into its loadout slot and destroys the live Model —
-- mirrors how bag contents are stored as data rather than kept as live Instances.
function Local.StashActiveItem(player: Player, character: Model)
	local slots = _loadoutSlots[player]
	if not slots then return end

	local activeSlot = character:GetAttribute("ActiveSlot") :: LoadoutSlot?
	if activeSlot ~= "Perk" and activeSlot ~= "Inventory" then return end

	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return end

	local heldModel = character:FindFirstChild(heldItemName)
	if not heldModel then return end

	local uid = Local.EnsureUID(heldModel)
	slots[activeSlot] = { itemName = heldItemName, uid = uid }

	Network:FireClient("Item", player, "ForceUnequip", heldModel)
	heldModel:Destroy()

	character:SetAttribute("HeldItem", "")
	character:SetAttribute("ActiveSlot", "")

	Local.RecalculateContraband(character)
end

-- Reconstructs the given slot's item from its stored data (respawns the Model fresh, matching
-- Shared.PopBagItem's reconstruct-from-data approach) and equips it as the new HeldItem.
function Local.ActivateSlot(player: Player, character: Model, slot: LoadoutSlot): boolean
	local slots = _loadoutSlots[player]
	local data = slots and slots[slot]
	if not data then return false end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return false end

	local item = Shared.SpawnItem(data.itemName, hrp.CFrame)
	if not item then return false end

	item:SetAttribute("UID", data.uid)
	if item:GetAttribute("IsBag") then
		Local.UpdateBagStats(item)
	end

	-- Set before equipping — EquipItemDirect syncs to the client as its last step.
	character:SetAttribute("ActiveSlot", slot)
	Local.EquipItemDirect(player, character, item)
	return true
end

-- Perk-only, no consumable stock touched — used for the round-start grant (via GrantLoadout below)
-- and for perk-loss recovery (successful deposit, jail release), which must not re-roll consumables.
function Shared.GrantPerkItem(player: Player, teamName: string): Model?
	local character = player.Character
	if not character then return nil end

	local playerData = DataService.GetData(player)
	if not playerData then return nil end

	local perkItemName = playerData.loadout[teamName]
	if not perkItemName then return nil end
	if _perkConsumed[player] then return nil end

	if Local.IsBagItem(perkItemName) then
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then return nil end

		local item = Shared.SpawnItem(perkItemName, hrp.CFrame)
		if not item then return nil end

		character:SetAttribute("ActiveSlot", "Inventory")

		if Shared.ForcePickupItem(player, item) then
			return item
		end

		item:Destroy()
		return nil
	end

	local slots = _loadoutSlots[player]
	if not slots then
		slots = { Perk = nil, Inventory = nil }
		_loadoutSlots[player] = slots
	end

	slots.Perk = { itemName = perkItemName, uid = HttpService:GenerateGUID(false) }

	if Local.ActivateSlot(player, character, "Perk") then
		return character:FindFirstChild(perkItemName) :: Model?
	end

	return nil
end

-- Consumable stock is only ever spent here — call this once per round (round start / late join),
-- never on perk-loss recovery, or players would get free reloads on every deposit/jail cycle.
function Shared.GrantLoadout(player: Player, teamName: string)
	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local playerData = DataService.GetData(player)
	if not playerData then return end

	_perkConsumed[player] = nil

	local perkItemName = playerData.loadout[teamName]

	if perkItemName and Local.IsBagItem(perkItemName) then
		-- Bag perks skip the perk/inventory swap entirely — the bag just is the inventory item.
		_loadoutSlots[player] = nil
		character:SetAttribute("ActiveSlot", "Inventory")

		local item = Shared.SpawnItem(perkItemName, hrp.CFrame)
		if not item or not Shared.ForcePickupItem(player, item) then
			if item then item:Destroy() end
			return
		end

		-- Snapshot first: RemoveItemStock below can prune this same live array mid-loop once stock hits 0.
		local consumables = table.clone(playerData.loadout.consumables)
		for _, consumableName in consumables do
			if (playerData.itemStock[consumableName] or 0) > 0 and Shared.AddItemToBag(item, consumableName) then
				DataService.UpdateData(player, { type = "RemoveItemStock", data = { itemName = consumableName, amount = 1 } })
			end
		end

		return
	end

	local slots: LoadoutSlots = { Perk = nil, Inventory = nil }

	if perkItemName then
		slots.Perk = { itemName = perkItemName, uid = HttpService:GenerateGUID(false) }
	end

	local firstConsumable = playerData.loadout.consumables[1]
	if firstConsumable and (playerData.itemStock[firstConsumable] or 0) > 0 then
		slots.Inventory = { itemName = firstConsumable, uid = HttpService:GenerateGUID(false) }
		DataService.UpdateData(player, { type = "RemoveItemStock", data = { itemName = firstConsumable, amount = 1 } })
	end

	_loadoutSlots[player] = slots

	local defaultSlot: LoadoutSlot? = if slots.Perk then "Perk" elseif slots.Inventory then "Inventory" else nil
	if defaultSlot then
		Local.ActivateSlot(player, character, defaultSlot)
	end
end

-- Swaps which loadout slot is physically held — no-ops if the target slot is empty, already active,
-- or the player is jailed (their equipped item was already dropped on arrest).
function Shared.SetActiveSlot(player: Player, slot: LoadoutSlot)
	local character = player.Character
	if not character then return end

	local slots = _loadoutSlots[player]
	if not slots or not slots[slot] then return end

	if character:GetAttribute("ActiveSlot") == slot then return end

	local record = JailService.GetRecord(player)
	if record and record.isJailed then return end

	Local.StashActiveItem(player, character)
	Local.ActivateSlot(player, character, slot)
end

function Local.InitializeItem(instance: Instance)
	if not instance:IsA("Model") then return end

	local primaryPart = instance.PrimaryPart
	if not primaryPart then
		warn(`[ItemService] Interactable Item "{instance.Name}" is missing a PrimaryPart!`)
		return
	end

	if instance:FindFirstChild("ItemWelds") then return end

	local itemName = instance.Name
	local itemConfig = ItemsConfig.GetItem(itemName)
	if not itemConfig then
		warn(`[ItemService] Interactable Item "{instance.Name}" has no config!`)
	else
		for attribute, value in itemConfig.attributes do
			instance:SetAttribute(attribute, value)
		end
	end

	-- Force this explicitly (rather than only setting it when present in the config) so a stale IsContraband=true baked onto the Studio template can't survive on an item whose config doesn't declare it.
	instance:SetAttribute("IsContraband", itemConfig ~= nil and itemConfig.attributes.IsContraband == true)

	local weldsFolder = Instance.new("Folder")
	weldsFolder.Name = "ItemWelds"
	weldsFolder.Parent = instance

	local gripWeld = Instance.new("WeldConstraint")
	gripWeld.Name = "GripWeld"
	gripWeld.Part1 = primaryPart
	gripWeld.Parent = weldsFolder

	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= primaryPart then
			local structWeld = Instance.new("WeldConstraint")
			structWeld.Name = `Weld_{descendant.Name}`
			structWeld.Part0 = primaryPart
			structWeld.Part1 = descendant
			structWeld.Parent = weldsFolder

			if not descendant:GetAttribute("OriginalCollisionGroup") then
				descendant:SetAttribute("OriginalCollisionGroup", descendant.CollisionGroup)
			end

			descendant.Anchored = false
		end
	end

	if not primaryPart:GetAttribute("OriginalCollisionGroup") then
		primaryPart:SetAttribute("OriginalCollisionGroup", primaryPart.CollisionGroup)
	end
end

function Local.SafeReposition(item: Model, targetCFrame: CFrame)
	for _, descendant in item:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end

	item:PivotTo(targetCFrame)

	task.defer(function()
		if not item or not item.Parent then return end

		for _, descendant in item:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = false
				descendant.CanCollide = true
			end
		end
	end)
end

function Local.MonitorItemRest(item: Model)
	task.spawn(function()
		local primary = item.PrimaryPart
		if not primary then return end

		local maxWaitTimeout = 5
		local elapsed = 0
		local restTicks = 0

		while item and item.Parent == ItemSpawnFolder and elapsed < maxWaitTimeout do
			local dt = task.wait(0.1)
			elapsed += dt

			if primary.AssemblyLinearVelocity.Magnitude < 0.5 then
				restTicks += 1
				if restTicks >= 3 then
					break
				end
			else
				restTicks = 0
			end
		end

		if item and item.Parent == ItemSpawnFolder then
			for _, descendant in item:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.CollisionGroup = descendant:GetAttribute("OriginalCollisionGroup") or "Default"
				end
			end

			CollectionService:AddTag(item, INTERACT_TAG)
		end
	end)
end

function Local.EnsureUID(model: Model): string
	local uid = model:GetAttribute("UID")
	if not uid then
		uid = HttpService:GenerateGUID(false)
		model:SetAttribute("UID", uid)
	end
	return uid
end

function Local.GetItemConfigAttributes(itemName: string): { Weight: number, Rating: number, IsContraband: boolean, MaxWeight: number? }
	local itemConfig = ItemsConfig.GetItem(itemName)
	local attributes = (itemConfig and itemConfig.attributes) or {}

	return {
		Weight = attributes.Weight or 1,
		Rating = attributes.Rating or 1,
		IsContraband = attributes.IsContraband == true,
		MaxWeight = attributes.MaxWeight,
	}
end

function Local.UpdateBagStats(bag: Model)
	local bagUid = bag:GetAttribute("UID")
	if not bagUid then return end

	local emptyWeight = bag:GetAttribute("EmptyWeight")
	if not emptyWeight then
		emptyWeight = bag:GetAttribute("Weight") or 1
		bag:SetAttribute("EmptyWeight", emptyWeight)
	end

	local emptyRating = bag:GetAttribute("EmptyRating")
	if not emptyRating then
		emptyRating = bag:GetAttribute("Rating") or 1
		bag:SetAttribute("EmptyRating", emptyRating)
	end

	local totalWeight = emptyWeight
	local maxRating = emptyRating

	local contents = _bagContents[bagUid]
	if contents then
		for _, entry in contents do
			local configAttrs = Local.GetItemConfigAttributes(entry.itemName)
			totalWeight += configAttrs.Weight

			if configAttrs.Rating > maxRating then
				maxRating = configAttrs.Rating
			end
		end
	end

	bag:SetAttribute("Weight", tonumber(string.format(tostring(totalWeight), "%.2f")))
	bag:SetAttribute("Rating", maxRating)
end

function Local.RecalculateContraband(character: Model)
	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then
		character:SetAttribute("HasContraband", false)
		return
	end

	local item = character:FindFirstChild(heldItemName)
	if not item or not item:IsA("Model") then
		character:SetAttribute("HasContraband", false)
		return
	end

	if item:GetAttribute("IsContraband") then
		character:SetAttribute("HasContraband", true)
		return
	end

	if item:GetAttribute("IsBag") then
		local bagUid = item:GetAttribute("UID")
		local contents = bagUid and _bagContents[bagUid]

		if contents then
			for _, entry in contents do
				if Local.GetItemConfigAttributes(entry.itemName).IsContraband then
					character:SetAttribute("HasContraband", true)
					return
				end
			end
		end
	end

	character:SetAttribute("HasContraband", false)
end

function Local.InsertBagEntry(bag: Model, itemName: string, uid: string): boolean
	local bagUid = Local.EnsureUID(bag)
	local configAttrs = Local.GetItemConfigAttributes(itemName)

	local emptyWeight = bag:GetAttribute("EmptyWeight") or bag:GetAttribute("Weight") or 1
	local currentWeight = bag:GetAttribute("Weight") or emptyWeight
	local maxWeight = bag:GetAttribute("MaxWeight") or 15

	if currentWeight + configAttrs.Weight > maxWeight then
		return false
	end

	if not _bagContents[bagUid] then
		_bagContents[bagUid] = {}
	end

	table.insert(_bagContents[bagUid], { itemName = itemName, uid = uid })
	Local.UpdateBagStats(bag)

	return true
end

function Local.StoreInBag(bag: Model, item: Model): boolean
	if item:GetAttribute("IsBag") then return false end

	local itemName = item:GetAttribute("ItemName") or item.Name
	local itemUid = Local.EnsureUID(item)

	local inserted = Local.InsertBagEntry(bag, itemName, itemUid)
	if not inserted then return false end

	item:Destroy()

	return true
end

function Local.WeldToHand(character: Model, item: Model): boolean
	local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local primaryPart = item.PrimaryPart
	if not rightHand or not primaryPart then
		warn(`[ItemService] WeldToHand({character:GetFullName()}, {item.Name}) — missing RightHand/PrimaryPart, skipping`)
		return false
	end

	CollectionService:RemoveTag(item, INTERACT_TAG)

	for _, descendant in item:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Massless = true
			descendant.Anchored = false
			descendant.CollisionGroup = descendant:GetAttribute("OriginalCollisionGroup") or "Default"
		end
	end

	item:PivotTo((rightHand :: BasePart).CFrame * CFrame.new(0, -0.5, 0))

	local weldsFolder = item:FindFirstChild("ItemWelds")
	local gripWeld = weldsFolder and (weldsFolder:FindFirstChild("GripWeld") :: WeldConstraint?)
	if gripWeld then
		gripWeld.Part0 = rightHand :: BasePart
	else
		warn(`[ItemService] WeldToHand({character:GetFullName()}, {item.Name}) — no GripWeld found (ItemWelds folder={weldsFolder ~= nil}), item will be parented unwelded`)
	end

	item.Parent = character
	return true
end

function Local.SwapGripWeldToMotor(item: Model): boolean
	local existingMotor = item:FindFirstChild("Handle_Motor")
	if existingMotor then
		existingMotor:Destroy()
	end

	local weldsFolder = item:FindFirstChild("ItemWelds")
	if not weldsFolder then
		warn(`[ItemService] SwapGripWeldToMotor({item.Name}) — no ItemWelds folder, skipping`)
		return false
	end

	local gripWeld = weldsFolder:FindFirstChild("GripWeld") :: WeldConstraint?
	if not gripWeld or not gripWeld.Part0 then
		warn(`[ItemService] SwapGripWeldToMotor({item.Name}) — GripWeld missing or Part0 unset (gripWeld={gripWeld ~= nil}, Part0={gripWeld and gripWeld.Part0 ~= nil}), skipping`)
		return false
	end

	local motor = Instance.new("Motor6D")
	motor.Name = "Handle_Motor"
	motor.Part0 = gripWeld.Part0
	motor.Part1 = gripWeld.Part1
	motor.Parent = item

	gripWeld.Part0 = nil
	return true
end

function Local.CloneItemTemplate(itemName: string): Model?
	if not ItemTemplatesFolder then
		warn("[ItemService] ReplicatedStorage.Assets.Items folder not found — cannot clone item template!")
		return nil
	end

	local spacedName = (itemName:gsub("(%l)(%u)", "%1 %2"))
	local template = ItemTemplatesFolder:FindFirstChild(spacedName) or ItemTemplatesFolder:FindFirstChild(itemName)
	if not template or not template:IsA("Model") then
		warn(`[ItemService] No item template found for "{itemName}" in Assets.Items!`)
		return nil
	end

	return template:Clone()
end

function Local.ClearEquipped(character: Model): Model?
	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return nil end

	local item = character:FindFirstChild(heldItemName)
	if not item or not item:IsA("Model") then return nil end

	local handleMotor = item:FindFirstChild("Handle_Motor")
	if handleMotor then
		handleMotor:Destroy()
	end

	local weldsFolder = item:FindFirstChild("ItemWelds")
	if weldsFolder then
		local gripWeld = weldsFolder:FindFirstChild("GripWeld") :: WeldConstraint
		if gripWeld then
			gripWeld.Part0 = nil
		end
	end

	for _, descendant in item:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = true
			descendant.Massless = false
			descendant.Anchored = false
			descendant.CollisionGroup = ITEMBASEPART_TAG
		end
	end

	item.Parent = ItemSpawnFolder
	CollectionService:AddTag(item, INTERACT_TAG)

	local owningPlayer = Players:GetPlayerFromCharacter(character)
	if owningPlayer then
		Network:FireClient("Item", owningPlayer, "ForceUnequip", item)

		-- The dropped item is now a free-standing world pickup, not this player's anymore — clear the
		-- slot record so a later ActivateSlot can't spawn a duplicate sharing its UID.
		local activeSlot = character:GetAttribute("ActiveSlot") :: LoadoutSlot?
		local slots = _loadoutSlots[owningPlayer]
		if slots and (activeSlot == "Perk" or activeSlot == "Inventory") then
			slots[activeSlot] = nil
		end
	end

	character:SetAttribute("HeldItem", "")
	character:SetAttribute("ActiveSlot", "")

	Local.RecalculateContraband(character)

	return item :: Model
end

-- Weight/rating computed from data alone (config base + any tracked bag contents), so a stashed
-- slot's stats can be reported to the client without needing a live Model.
function Local.BuildSyncItemData(itemName: string, uid: string): ItemSyncData
	local baseAttrs = Local.GetItemConfigAttributes(itemName)
	local totalWeight = baseAttrs.Weight
	local maxRating = baseAttrs.Rating

	local contents = _bagContents[uid]
	if contents then
		for _, entry in contents do
			local entryAttrs = Local.GetItemConfigAttributes(entry.itemName)
			totalWeight += entryAttrs.Weight
			if entryAttrs.Rating > maxRating then
				maxRating = entryAttrs.Rating
			end
		end
	end

	return {
		name = itemName,
		weight = totalWeight,
		rating = maxRating,
		isBag = Local.IsBagItem(itemName),
		uid = uid,
		iconId = Local.GetItemIconId(itemName),
		maxWeight = baseAttrs.MaxWeight,
	}
end

function Local.SyncClient(player: Player, action: string)
	local character = player.Character
	if not character then return end

	local heldItemName = character:GetAttribute("HeldItem")
	local heldItem: ItemSyncData? = nil
	local bagContents: { BagSlotData }? = nil

	if heldItemName and heldItemName ~= "" then
		local item = character:FindFirstChild(heldItemName)
		if item and item:IsA("Model") then
			local uid = item:GetAttribute("UID") or ""
			heldItem = Local.BuildSyncItemData(item:GetAttribute("ItemName") or item.Name, uid)

			if heldItem.isBag and _bagContents[uid] then
				bagContents = {}
				for _, entry in _bagContents[uid] do
					local configAttrs = Local.GetItemConfigAttributes(entry.itemName)
					table.insert(bagContents, {
						name = entry.itemName,
						weight = configAttrs.Weight,
						rating = configAttrs.Rating,
						iconId = Local.GetItemIconId(entry.itemName),
					})
				end
			end
		end
	end

	local activeSlot = character:GetAttribute("ActiveSlot") :: LoadoutSlot?
	local slots = _loadoutSlots[player]
	local perkItem: ItemSyncData? = nil
	local inventoryItem: ItemSyncData? = nil

	if slots then
		if slots.Perk then
			perkItem = if activeSlot == "Perk" then heldItem else Local.BuildSyncItemData(slots.Perk.itemName, slots.Perk.uid)
		end
		if slots.Inventory then
			inventoryItem = if activeSlot == "Inventory" then heldItem else Local.BuildSyncItemData(slots.Inventory.itemName, slots.Inventory.uid)
		end
	elseif activeSlot == "Inventory" then
		-- Bag perks never populate _loadoutSlots (single-slot regime, no separate Perk slot) —
		-- the bag is just Slot 1.
		inventoryItem = heldItem
	end

	local payload: SyncPayload = {
		action = action,
		heldItem = heldItem,
		bagContents = bagContents,
		perkItem = perkItem,
		inventoryItem = inventoryItem,
		activeSlot = (activeSlot and activeSlot ~= "") and activeSlot or nil,
	}

	Network:FireClient("Inventory", player, "Sync", payload)
end

function Local.SetupThrowRagdoll(item: Model, thrower: Player, direction: Vector3, throwForce: number)
	local weight = item:GetAttribute("Weight") or 1
	if weight < RAGDOLL_THROW_WEIGHT then return end

	local connections: { RBXScriptConnection } = {}
	local triggered = false

	local function cleanup()
		for _, conn in connections do
			conn:Disconnect()
		end
		table.clear(connections)
		
		if _activeThrowListeners[item] == cleanup then
			_activeThrowListeners[item] = nil
		end
	end

	_activeThrowListeners[item] = cleanup

	for _, part in item:GetDescendants() do
		if part:IsA("BasePart") then
			local conn = part.Touched:Connect(function(hitPart: BasePart)
				if triggered then return end

				local hitCharacter = hitPart.Parent
				if not hitCharacter or not hitCharacter:IsA("Model") then return end

				local humanoid = hitCharacter:FindFirstChildOfClass("Humanoid")
				if not humanoid or humanoid.Health <= 0 then return end

				local hitPlayer = Players:GetPlayerFromCharacter(hitCharacter)
				if hitPlayer == thrower then return end

				triggered = true

				local target: Player | Model = hitPlayer or hitCharacter
				local impactForce = throwForce * RAGDOLL_IMPACT_FORCE_MULTIPLIER

				RagdollService.Ragdoll(target, hitPart.Position, direction, impactForce)

				cleanup()
			end)

			table.insert(connections, conn)
		end
	end

	task.delay(RAGDOLL_LISTEN_TIMEOUT, cleanup)
end

-- [[ Public Functions ]] --
function Local.GrantItem(player: Player, character: Model, hrp: BasePart, item: Model): boolean
	local pendingThrowCleanup = _activeThrowListeners[item]
	if pendingThrowCleanup then
		pendingThrowCleanup()
	end

	local currentHeld = character:GetAttribute("HeldItem")
	if currentHeld and currentHeld ~= "" then
		local heldModel = character:FindFirstChild(currentHeld)

		if heldModel and heldModel:GetAttribute("IsBag") then
			if item:GetAttribute("IsBag") then
				warn(`[ItemService] GrantItem({player.Name}, {item.Name}) — already holding bag "{currentHeld}", can't nest a bag inside a bag; item stays dropped in the world`)
				return false
			end

			local success = Local.StoreInBag(heldModel, item)

			Local.RecalculateContraband(character)

			Local.SyncClient(player, "ItemPickup")
			if not success then
				warn(`[ItemService] GrantItem({player.Name}, {item.Name}) — bag "{currentHeld}" is too heavy to hold it`)
			end
			return success
		end

		-- A held Perk item is never dropped by an ordinary pickup — it gets stashed back to its slot
		-- instead, and the new item takes over the Inventory slot below.
		if _loadoutSlots[player] and character:GetAttribute("ActiveSlot") == "Perk" then
			Local.StashActiveItem(player, character)
		else
			local droppedItem = Local.ClearEquipped(character)
			if droppedItem and droppedItem.PrimaryPart then
				Local.SafeReposition(droppedItem, hrp.CFrame * CFrame.new(0, 0, -3))
				Local.MonitorItemRest(droppedItem)
			end
		end
	end

	-- Set before equipping — EquipItemDirect syncs to the client as its last step, and the payload
	-- needs ActiveSlot/loadoutSlots already up to date at that point.
	character:SetAttribute("ActiveSlot", "Inventory")

	if _loadoutSlots[player] then
		_loadoutSlots[player].Inventory = { itemName = item.Name, uid = Local.EnsureUID(item) }
	end

	Local.EquipItemDirect(player, character, item)

	return true
end

function Shared.PickupItem(player: Player, item: Model, originCFrame: CFrame): boolean
	local character = player.Character
	if not character then return false end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not hrp or not item.PrimaryPart then return false end
	if item.Parent == character or not item.Parent then return false end

	if not CollectionService:HasTag(item, INTERACT_TAG) then return false end

	local rayOrigin = originCFrame.Position
	local itemPos = item:GetPivot().Position
	local direction = itemPos - rayOrigin
	local distance = direction.Magnitude

	if distance > MAX_PICKUP_DISTANCE then return false end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character, item }
	if Workspace:Raycast(rayOrigin, direction.Unit * distance, rayParams) then return false end

	if (hrp.Position - itemPos).Magnitude > MAX_PICKUP_DISTANCE then return false end

	return Local.GrantItem(player, character, hrp, item)
end

function Shared.ForcePickupItem(player: Player, item: Model): boolean
	local character = player.Character
	if not character then return false end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not hrp or not item.PrimaryPart then return false end
	if item.Parent == character or not item.Parent then return false end

	return Local.GrantItem(player, character, hrp, item)
end

function Shared.PopBagItem(player: Player)
	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" or not hrp then return end

	local bag = character:FindFirstChild(heldItemName)
	if not bag or not bag:GetAttribute("IsBag") then return end

	local bagUid = bag:GetAttribute("UID")
	if not bagUid or not _bagContents[bagUid] or #_bagContents[bagUid] == 0 then return end

	local entry: BagEntry = table.remove(_bagContents[bagUid], #_bagContents[bagUid]) :: BagEntry

	local clone = Local.CloneItemTemplate(entry.itemName)
	if not clone or not clone.PrimaryPart then
		table.insert(_bagContents[bagUid], entry)
		return
	end

	clone.Name = entry.itemName
	clone:SetAttribute("UID", entry.uid)

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant:SetAttribute("OriginalCollisionGroup", descendant.CollisionGroup)
			descendant.CollisionGroup = ITEMBASEPART_TAG
		end
	end

	clone.Parent = ItemSpawnFolder
	Local.SafeReposition(clone, hrp.CFrame * CFrame.new(0, 0, -2.5))
	Local.MonitorItemRest(clone)

	CollectionService:AddTag(clone, INTERACT_TAG)

	Local.UpdateBagStats(bag)
	Local.RecalculateContraband(character)

	Local.SyncClient(player, "BagPop")
end

function Shared.ThrowItem(player: Player, originCFrame: CFrame, direction: Vector3)
	local character = player.Character
	if not character then return end
	if character:GetAttribute("ActiveSlot") == "Perk" then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not hrp then return end

	local droppedItem = Local.ClearEquipped(character)
	if droppedItem and droppedItem.PrimaryPart then
		CollectionService:RemoveTag(droppedItem, INTERACT_TAG)
		CollectionService:AddTag(droppedItem, "THROWN_ITEM")

		local primary = droppedItem.PrimaryPart
		primary.AssemblyLinearVelocity = direction * THROW_FORCE

		task.delay(.25, function()
			CollectionService:RemoveTag(droppedItem, "THROWN_ITEM")
		end)

		Local.SetupThrowRagdoll(droppedItem, player, direction, THROW_FORCE)
		Local.MonitorItemRest(droppedItem)

		Local.SyncClient(player, "ItemThrown")
	end
end

function Shared.DropItem(player: Player)
	local character = player.Character
	if not character then return end
	if character:GetAttribute("ActiveSlot") == "Perk" then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not hrp then return end

	local droppedItem = Local.ClearEquipped(character)
	if droppedItem and droppedItem.PrimaryPart then
		-- Same approach as ThrowItem — launch from wherever ClearEquipped left it (still at the hand,
		-- so always somewhere valid) instead of teleporting it forward, which had no floor/wall
		-- validation and could land the item inside geometry or past a railing/map edge.
		droppedItem.PrimaryPart.AssemblyLinearVelocity = hrp.CFrame.LookVector * DROP_FORCE
		Local.MonitorItemRest(droppedItem)

		Local.SyncClient(player, "ItemDropped")
	end
end

function Shared.UseItem(player: Player, ...:any)
	local character = player.Character
	if not character then return end

	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return end

	if not ItemsConfig.IsItemUsable(heldItemName) then return end

	local itemModule = ItemsConfig.GetItem(heldItemName)
	if not itemModule or not itemModule.Use then return end

	local consume = function()
		Shared.ConsumeEquipped(player)
	end

	itemModule.Use(player, consume, ...)
end

function Shared.ConsumeEquipped(player: Player)
	local character = player.Character
	if not character then return end

	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return end

	local item = character:FindFirstChild(heldItemName)
	if not item or not item:IsA("Model") then return end
	
	local uid = item:GetAttribute("UID")
	if uid and _bagContents[uid] then
		_bagContents[uid] = nil
	end

	local activeSlot = character:GetAttribute("ActiveSlot") :: LoadoutSlot?
	if activeSlot == "Perk" then
		_perkConsumed[player] = true
		local slots = _loadoutSlots[player]
		if slots then
			slots.Perk = nil
		end
	end

	character:SetAttribute("HeldItem", "")
	character:SetAttribute("ActiveSlot", "")

	Local.RecalculateContraband(character)

	Network:FireClient("Item", player, "ForceUnequip", item)

	item:Destroy()
	Local.SyncClient(player, "ItemConsumed")
end

function Shared.IsHoldingBag(player: Player): boolean
	local character = player.Character
	if not character then return false end

	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return false end

	local item = character:FindFirstChild(heldItemName)
	if not item or not item:IsA("Model") then return false end

	return item:GetAttribute("IsBag") == true
end

function Shared.ForceDropItem(character: Model): Model?
	return Local.ClearEquipped(character)
end

-- For callers that ForceDropItem an item off a character and then, on a later failure (e.g. a
-- steal's handoff to the player not going through), need to place it properly in the world instead
-- of leaving it wherever its stale in-hand pose left it — mirrors DropItem's own settle behavior.
function Shared.SettleItem(item: Model, anchor: BasePart)
	if not item or not item.PrimaryPart then return end
	Local.SafeReposition(item, anchor.CFrame * CFrame.new(0, 0, -2.5))
	Local.MonitorItemRest(item)
end

function Shared.GetContrabandRating(item: Model): number
	if item:GetAttribute("IsContraband") then
		return item:GetAttribute("Rating") or 0
	end

	if item:GetAttribute("IsBag") then
		local bagUid = item:GetAttribute("UID")
		local contents = bagUid and _bagContents[bagUid]
		if not contents then return 0 end

		local total = 0
		for _, entry in contents do
			local configAttrs = Local.GetItemConfigAttributes(entry.itemName)
			if configAttrs.IsContraband then
				total += configAttrs.Rating
			end
		end
		return total
	end

	return 0
end

function Shared.GetContrabandItemCount(item: Model): number
	if item:GetAttribute("IsContraband") then
		return 1
	end

	if item:GetAttribute("IsBag") then
		local bagUid = item:GetAttribute("UID")
		local contents = bagUid and _bagContents[bagUid]
		if not contents then return 0 end

		local count = 0
		for _, entry in contents do
			if Local.GetItemConfigAttributes(entry.itemName).IsContraband then
				count += 1
			end
		end
		return count
	end

	return 0
end

-- Blockcasts the item's own footprint straight down so it lands flush on whatever surface is there
function Local.PlaceItemOnSurface(item: Model, cframe: CFrame): CFrame
	local extentsSize = item:GetExtentsSize()

	local castParams = RaycastParams.new()
	castParams.FilterType = Enum.RaycastFilterType.Exclude
	castParams.FilterDescendantsInstances = { item }

	local origin = cframe.Position + Vector3.new(0, SPAWN_DROP_HEIGHT, 0)
	local castSize = Vector3.new(math.max(extentsSize.X, 0.1), SPAWN_CAST_THICKNESS, math.max(extentsSize.Z, 0.1))

	local result = Workspace:Blockcast(CFrame.new(origin), castSize, Vector3.new(0, -SPAWN_MAX_DROP, 0), castParams)
	local surfaceY = if result then result.Position.Y else cframe.Position.Y

	return (cframe - cframe.Position) + Vector3.new(cframe.Position.X, surfaceY + extentsSize.Y / 2, cframe.Position.Z)
end

function Shared.SpawnItem(itemName: string, cframe: CFrame?): Model?
	local item = Local.CloneItemTemplate(itemName)
	if not item then return nil end

	CollectionService:AddTag(item, INTERACT_TAG)
	Local.InitializeItem(item)

	if cframe then
		item:PivotTo(Local.PlaceItemOnSurface(item, cframe))
	end

	item.Parent = ItemSpawnFolder
	return item
end

function Shared.EquipNPCItem(npcModel: Model, item: Model): boolean
	if not npcModel or not item or not item.PrimaryPart then return false end

	local currentHeld = npcModel:GetAttribute("HeldItem")
	if currentHeld and currentHeld ~= "" then
		warn(`[ItemService] NPC "{npcModel.Name}" is already holding "{currentHeld}"!`)
		return false
	end

	Local.EnsureUID(item)
	npcModel:SetAttribute("HeldItem", item.Name)

	if not Local.WeldToHand(npcModel, item) then
		npcModel:SetAttribute("HeldItem", "")
		return false
	end

	if not Local.SwapGripWeldToMotor(item) then
		warn(`[ItemService] EquipNPCItem({npcModel.Name}, {item.Name}) — Motor6D swap failed, item will stay weld-only`)
	end

	Local.RecalculateContraband(npcModel)

	return true
end

function Shared.AddItemToBag(bag: Model, itemName: string): boolean
	if not bag or not itemName or itemName == "" then return false end
	if not bag:GetAttribute("IsBag") then return false end

	local itemUid = HttpService:GenerateGUID(false)
	local inserted = Local.InsertBagEntry(bag, itemName, itemUid)
	if not inserted then return false end

	local character = bag.Parent
	local owningPlayer = character and Players:GetPlayerFromCharacter(character)
	if owningPlayer then
		Local.SyncClient(owningPlayer, "BagStore")
	end

	return true
end

function Shared.Destroy()
	if _stopTagObserver then
		_stopTagObserver()
		_stopTagObserver = nil
	end

	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	table.clear(_loadoutSlots)
	table.clear(_perkConsumed)
end

return Shared