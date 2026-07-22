--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local PlayerDataTemplate = require(ReplicatedStorage.Modules.PlayerDataTemplate)
local UpdateData = require(ReplicatedStorage.Modules.Functions.UpdateData)
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

--|| Types
export type PlayerData = PlayerDataTemplate.PlayerData
export type UpdateAction = UpdateData.UpdateAction

--|| Variables
local _cachedData: PlayerData? = nil

--|| MAIN ||--
local Local = {}
local Shared = {}

Shared.Priority = -1
Shared.OnDataChanged = ModuleUtils.signal.new()

-- [[ Startup ]] --
function Shared.Init()
	Network:FireServer("PlayerData", "Sync")

	Network:BindEventOnce("PlayerData", "Sync", function(data: PlayerData)
		_cachedData = data
		warn(data)
	end)

	Network:BindEvent("PlayerData", "Update", function(payload: { action: UpdateAction?, data: PlayerData? })
		if payload.action then
			UpdateData(_cachedData, payload.action)
		elseif payload.data then
			_cachedData = payload.data
		end

		Shared.OnDataChanged:Fire(payload.action, _cachedData)
	end)
end

function Shared.Start() end

-- [[ Public Functions ]] --
function Shared.GetData(): PlayerData
	while not _cachedData do
		task.wait()
	end

	return _cachedData
end

function Shared.RequestUpdate(action: UpdateAction)
	Network:FireServer("PlayerData", "Update", action)
end

return Shared