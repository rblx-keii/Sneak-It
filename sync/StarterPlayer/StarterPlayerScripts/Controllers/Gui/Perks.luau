--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local PerksConfig = require(ReplicatedStorage.Modules.Configs.PerksConfig)
local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)
local GuiController = require(script.Parent.Parent.GuiController)
local DataController = require(script.Parent.Parent.DataController)

local Gui = GuiController.Guis.Perks
local content = Gui.Frame.Content
local container = content.Container
local itemsFrame = container.Items :: ScrollingFrame
local footerInfo = container.Footer.Info
local footerTitle = footerInfo.Title :: TextLabel
local footerIcon = footerInfo.IconContainer.Icon :: ImageLabel

local tabsFrame = Gui.Frame.Tabs
local smugglerTabButton = tabsFrame.Smuggler.Button :: ImageButton
local securityTabButton = tabsFrame.Security.Button :: ImageButton

--|| Types
type Team = PerksConfig.Team

type Slot = {
	frame: Frame,
	content: Frame,
	title: TextLabel,
	subtitle: TextLabel,
	description: TextLabel,
	icon: ImageLabel,
	unlockedButton: Frame,
	equipButton: TextButton,
	equipLabel: TextLabel,
	lockedButton: Frame,
	lockedLabel: TextLabel,
}

--|| Variables
local _networkConnections: { Network.Cleanup } = {}
local _connections: { RBXScriptConnection } = {}
local _slots: { Slot } = {}
local _activeTeam: Team = "Smuggler"
local _ownedItems: { [string]: boolean } = {}
local _loadout: { Smuggler: string?, TSA: string? } = {}

--|| Constants
local SLOT_NAMES = { "Perk_1", "Perk_2", "Perk_3" }
local TAB_ACTIVE_TRANSPARENCY = 0
local TAB_INACTIVE_TRANSPARENCY = 0.5

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Local.BuildSlots()

	table.insert(_connections, smugglerTabButton.Activated:Connect(function()
		Local.SetActiveTeam("Smuggler")
	end))

	table.insert(_connections, securityTabButton.Activated:Connect(function()
		Local.SetActiveTeam("TSA")
	end))

	table.insert(_networkConnections, Network:BindEvent("Perks", "EquipResult", function(result: { success: boolean, reason: string? })
		if not result.success then
			warn("[Perks] Equip failed:", result.reason)
		end
	end))

	table.insert(_connections, DataController.OnDataChanged:Connect(function(_action, data: DataController.PlayerData)
		Local.ApplyData(data)
	end))

	Local.SetActiveTeam("Smuggler")
end

function Shared.Start()
	task.spawn(function()
		Local.ApplyData(DataController.GetData())
	end)
end

-- [[ Private Functions ]] --
function Local.IsLockedButton(button: Frame): boolean
	return button:FindFirstChild("Lock") ~= nil
end

-- Every slot's Content has a single "Button" frame whose contents differ depending on which state
-- the Studio template happened to be authored in (Perk_1 ships the clickable/equip look, Perk_2 and
-- Perk_3 ship the locked look) — but any slot can be in either state at runtime, so the missing
-- variant is cloned in from whichever slot already has it and both are kept as hidden/shown
-- siblings. Runtime-only patch; the synced GUI files are never touched.
function Local.BuildSlots()
	local unlockedSource: Frame? = nil
	local lockedSource: Frame? = nil

	for _, slotName in SLOT_NAMES do
		local frame = itemsFrame:FindFirstChild(slotName) :: Frame?
		if not frame then continue end
		local slotContent = frame:FindFirstChild("Content") :: Frame
		local button = slotContent:FindFirstChild("Button") :: Frame?
		if not button then continue end

		if Local.IsLockedButton(button) then
			lockedSource = lockedSource or button
		else
			unlockedSource = unlockedSource or button
		end
	end

	for _, slotName in SLOT_NAMES do
		local frame = itemsFrame:FindFirstChild(slotName) :: Frame?
		if not frame then continue end
		local slotContent = frame:FindFirstChild("Content") :: Frame
		local existingButton = slotContent:FindFirstChild("Button") :: Frame?
		if not existingButton then continue end

		local unlockedButton: Frame
		local lockedButton: Frame

		if Local.IsLockedButton(existingButton) then
			lockedButton = existingButton
			unlockedButton = if unlockedSource then unlockedSource:Clone() else existingButton
		else
			unlockedButton = existingButton
			lockedButton = if lockedSource then lockedSource:Clone() else existingButton
		end

		if unlockedButton ~= existingButton then unlockedButton.Parent = slotContent end
		if lockedButton ~= existingButton then lockedButton.Parent = slotContent end

		local slot: Slot = {
			frame = frame,
			content = slotContent,
			title = slotContent:FindFirstChild("Title") :: TextLabel,
			subtitle = slotContent:FindFirstChild("SubTitle") :: TextLabel,
			description = slotContent:FindFirstChild("Description") :: TextLabel,
			icon = slotContent:FindFirstChild("Icon") :: ImageLabel,
			unlockedButton = unlockedButton,
			equipButton = unlockedButton:FindFirstChild("Button") :: TextButton,
			equipLabel = unlockedButton:FindFirstChild("Label") :: TextLabel,
			lockedButton = lockedButton,
			lockedLabel = lockedButton:FindFirstChild("Label") :: TextLabel,
		}

		table.insert(_connections, slot.equipButton.Activated:Connect(function()
			Local.RequestEquipSlot(slot)
		end))

		table.insert(_slots, slot)
	end
end

function Local.RequestEquipSlot(slot: Slot)
	local index = table.find(_slots, slot)
	if not index then return end

	local entry = PerksConfig.GetTeamEntries(_activeTeam)[index]
	if not entry then return end
	if not _ownedItems[entry.itemName] then return end
	if _loadout[_activeTeam] == entry.itemName then return end

	Network:FireServer("Perks", "RequestEquip", { team = _activeTeam, itemName = entry.itemName })
end

function Local.ApplyData(data: DataController.PlayerData)
	_ownedItems = data.ownedItems
	_loadout = data.loadout
	Local.RefreshSlots()
end

function Local.SetActiveTeam(team: Team)
	_activeTeam = team

	smugglerTabButton.ImageTransparency = if team == "Smuggler" then TAB_ACTIVE_TRANSPARENCY else TAB_INACTIVE_TRANSPARENCY
	securityTabButton.ImageTransparency = if team == "TSA" then TAB_ACTIVE_TRANSPARENCY else TAB_INACTIVE_TRANSPARENCY

	Local.RefreshSlots()
end

function Local.RefreshSlots()
	local entries = PerksConfig.GetTeamEntries(_activeTeam)
	local equippedItemName = _loadout[_activeTeam]
	local equippedDisplayName = "None"
	local equippedIconId: number? = nil

	for index, slot in _slots do
		local entry = entries[index]
		if not entry then
			slot.frame.Visible = false
			continue
		end

		slot.frame.Visible = true
		slot.title.Text = entry.displayName
		slot.description.Text = entry.description

		local itemModule = ItemsConfig.GetItem(entry.itemName)
		local iconId = itemModule and itemModule.properties.iconId
		slot.icon.Image = if iconId then `rbxassetid://{iconId}` else ""

		local owned = _ownedItems[entry.itemName] == true
		local equipped = equippedItemName == entry.itemName

		if equipped then
			equippedDisplayName = entry.displayName
			equippedIconId = iconId
		end

		slot.unlockedButton.Visible = owned
		slot.lockedButton.Visible = not owned

		if owned then
			slot.subtitle.Text = if entry.winsRequired <= 0 then "Free/Default" else "Unlocked"
			slot.equipLabel.Text = if equipped then "Equipped" else "Equip"
		else
			slot.subtitle.Text = if entry.winsRequired > 0 then `{entry.winsRequired} Wins to Unlock` else "Locked"
			slot.lockedLabel.Text = if entry.winsRequired > 0 then `Reach {entry.winsRequired} Wins to Unlock` else "Locked"
		end
	end

	footerTitle.Text = `<font color="rgb(20,150,59)">Selected Perk:</font><font color="rgb(0,0,0)"> {equippedDisplayName}</font>`
	footerIcon.Image = if equippedIconId then `rbxassetid://{equippedIconId}` else ""
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
end

return Shared
