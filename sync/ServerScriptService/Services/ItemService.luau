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

local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)

local JailService = require(script.Parent.JailService)
local RagdollService = require(script.Parent.RagdollService)

local DebrisFolder = ReplicatedStorage:FindFirstChild("Debris") or ReplicatedStorage
local _assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
local ItemTemplatesFolder = _assetsFolder and _assetsFolder:FindFirstChild("Items")

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _stopTagObserver: (() -> ())? = nil
local _bagContents: { [string]: { BagEntry } } = {}

local _activeThrowListeners: { [Model]: () -> () } = {}

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

type BagEntry = {
	itemName: string,
	uid: string,
}

type SyncPayload = {
	action: "ItemPickup" | "ItemDropped" | "ItemThrown" | "BagStore" | "BagPop" | "ItemConsumed",
	heldItem: ItemSyncData?,
	bagContents: { BagSlotData }?,
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

--|| MAIN ||--
local Local = {}
local Shared = {}

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

	JailService.OnJailed:Connect(function(player: Player)
		local character = player.Character
		if not character then return end
		Local.ClearEquipped(character)
	end)

	RagdollService.OnPlayerRagdolled:Connect(function(player: Player)
		local character = player.Character
		if not character then return end
		Local.ClearEquipped(character)
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
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

		while item and item.Parent == Workspace and elapsed < maxWaitTimeout do
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

		if item and item.Parent == Workspace then
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

function Local.GetItemConfigAttributes(itemName: string): { Weight: number, Rating: number, IsContraband: boolean }
	local itemConfig = ItemsConfig.GetItem(itemName)
	local attributes = (itemConfig and itemConfig.attributes) or {}

	return {
		Weight = attributes.Weight or 1,
		Rating = attributes.Rating or 1,
		IsContraband = attributes.IsContraband == true,
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

function Local.WeldToHand(character: Model, item: Model)
	local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local primaryPart = item.PrimaryPart
	if not rightHand or not primaryPart then return end

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
	if weldsFolder then
		local gripWeld = weldsFolder:FindFirstChild("GripWeld") :: WeldConstraint
		if gripWeld then
			gripWeld.Part0 = rightHand :: BasePart
		end
	end

	item.Parent = character
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

	item.Parent = Workspace
	CollectionService:AddTag(item, INTERACT_TAG)

	local owningPlayer = Players:GetPlayerFromCharacter(character)
	if owningPlayer then
		Network:FireClient("Item", owningPlayer, "ForceUnequip", item)
	end

	character:SetAttribute("HeldItem", "")

	Local.RecalculateContraband(character)

	return item :: Model
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
			local isBag = item:GetAttribute("IsBag") == true
			local uid = item:GetAttribute("UID") or ""

			heldItem = {
				name = item:GetAttribute("ItemName") or item.Name,
				weight = item:GetAttribute("Weight") or 1,
				rating = item:GetAttribute("Rating") or 1,
				isBag = isBag,
				uid = uid,
			}

			if isBag and _bagContents[uid] then
				bagContents = {}
				for _, entry in _bagContents[uid] do
					local configAttrs = Local.GetItemConfigAttributes(entry.itemName)
					table.insert(bagContents, {
						name = entry.itemName,
						weight = configAttrs.Weight,
						rating = configAttrs.Rating,
					})
				end
			end
		end
	end

	local payload: SyncPayload = {
		action = action,
		heldItem = heldItem,
		bagContents = bagContents,
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
function Shared.PickupItem(player: Player, item: Model, originCFrame: CFrame)
	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not hrp or not item.PrimaryPart then return end
	if item.Parent == character or not item.Parent then return end

	if not CollectionService:HasTag(item, INTERACT_TAG) then return end

	local rayOrigin = originCFrame.Position
	local itemPos = item:GetPivot().Position
	local direction = itemPos - rayOrigin
	local distance = direction.Magnitude

	if distance > MAX_PICKUP_DISTANCE then return end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character, item }
	if Workspace:Raycast(rayOrigin, direction.Unit * distance, rayParams) then return end

	if (hrp.Position - itemPos).Magnitude > MAX_PICKUP_DISTANCE then return end

	local pendingThrowCleanup = _activeThrowListeners[item]
	if pendingThrowCleanup then
		pendingThrowCleanup()
	end

	local currentHeld = character:GetAttribute("HeldItem")
	if currentHeld and currentHeld ~= "" then
		local heldModel = character:FindFirstChild(currentHeld)

		if heldModel and heldModel:GetAttribute("IsBag") then
			local success = Local.StoreInBag(heldModel, item)

			Local.RecalculateContraband(character)

			Local.SyncClient(player, "ItemPickup")
			if not success then
				warn(`[ItemService] {player.Name}'s bag is too heavy to hold {item.Name}!`)
			end
			return
		end

		local droppedItem = Local.ClearEquipped(character)
		if droppedItem and droppedItem.PrimaryPart then
			Local.SafeReposition(droppedItem, hrp.CFrame * CFrame.new(0, 0, -3))
			Local.MonitorItemRest(droppedItem)
		end
	end

	Local.EnsureUID(item)
	character:SetAttribute("HeldItem", item.Name)
	Local.WeldToHand(character, item)

	Local.RecalculateContraband(character)

	Local.SyncClient(player, "ItemPickup")
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

	clone.Parent = Workspace
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

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not hrp then return end

	local droppedItem = Local.ClearEquipped(character)
	if droppedItem then
		Local.SafeReposition(droppedItem, hrp.CFrame * CFrame.new(0, 0, -2.5))
		droppedItem.PrimaryPart:ApplyImpulseAtPosition(hrp.CFrame.LookVector * DROP_FORCE * droppedItem.PrimaryPart.AssemblyMass, droppedItem.PrimaryPart.Position)
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
	character:SetAttribute("HeldItem", "")

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

function Shared.SpawnItem(itemName: string, cframe: CFrame?): Model?
	local item = Local.CloneItemTemplate(itemName)
	if not item then return nil end

	CollectionService:AddTag(item, INTERACT_TAG)
	Local.InitializeItem(item)

	if cframe then
		item:PivotTo(cframe)
	end

	item.Parent = Workspace
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
	Local.WeldToHand(npcModel, item)
	Local.RecalculateContraband(npcModel)

	return true
end

function Shared.AddItemToBag(bag: Model, itemName: string): boolean
	if not bag or not itemName or itemName == "" then return false end
	if not bag:GetAttribute("IsBag") then return false end

	local itemUid = HttpService:GenerateGUID(false)
	return Local.InsertBagEntry(bag, itemName, itemUid)
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
end

return Shared