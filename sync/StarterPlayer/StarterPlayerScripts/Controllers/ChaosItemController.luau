--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local ItemController = require(script.Parent.ItemController)
local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)
local Network = require(ReplicatedStorage.Modules.Network)

--|| Variables
local _equipConnection: RBXScriptConnection? = nil
local _unequipConnection: RBXScriptConnection? = nil

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	_equipConnection = ItemController.OnItemEquipped:Connect(Local.OnItemEquipped)
	_unequipConnection = ItemController.OnItemUnequipped:Connect(Local.OnItemUnequipped)
end

function Shared.Start() end

-- [[ Private Functions ]] --
function Local.OnItemEquipped(itemName: string, itemModel: Instance?)
	local itemModule = ItemsConfig.GetItem(itemName)
	if not itemModule then return end

	if itemModule.OnEquip then
		itemModule.OnEquip(itemModel)
	end
end

function Local.OnItemUnequipped(itemName: string, itemModel: Instance?)
	local itemModule = ItemsConfig.GetItem(itemName)
	if not itemModule then return end

	if itemModule.OnUnequip then
		itemModule.OnUnequip(itemModel)
	end
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	if _equipConnection then
		_equipConnection:Disconnect()
		_equipConnection = nil
	end

	if _unequipConnection then
		_unequipConnection:Disconnect()
		_unequipConnection = nil
	end
end

return Shared