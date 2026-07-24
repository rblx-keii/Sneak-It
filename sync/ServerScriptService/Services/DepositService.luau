--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--|| References
local ZonePlus = require(ReplicatedStorage.Modules.Libs.ZonePlus)
local RoundService = require(script.Parent.RoundService)
local JailService = require(script.Parent.JailService)
local SpawnService = require(script.Parent.SpawnService)
local ItemService = require(script.Parent.ItemService)
local DataService = require(script.Parent.DataService)
local TeamService = require(script.Parent.TeamService)
local RewardService = require(script.Parent.RewardService)

--|| Variables
local _zones: {[BasePart]: ZonePlus.ZoneType} = {}
local _depositThreads: {[Player]: thread} = {}
local _depositConnections: {[Player]: RBXScriptConnection} = {}
local _connections: {RBXScriptConnection} = {}

--|| Constants
local DEPOSIT_TIME = 5
local DEPOSIT_ZONE_TAG = "DepositZone"
local TOKENS_PER_STAR = 3

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	for _, part in CollectionService:GetTagged(DEPOSIT_ZONE_TAG) do
		Local.SetupZone(part)
	end

	table.insert(_connections, CollectionService:GetInstanceAddedSignal(DEPOSIT_ZONE_TAG):Connect(Local.SetupZone))
	table.insert(_connections, CollectionService:GetInstanceRemovedSignal(DEPOSIT_ZONE_TAG):Connect(Local.RemoveZone))

	table.insert(_connections, Players.PlayerRemoving:Connect(Local.CancelDeposit))
	table.insert(_connections, JailService.OnJailed:Connect(Local.CancelDeposit))

	-- Cancel every in-flight deposit as soon as the boarding window closes,
	-- rather than letting them silently fail once their timer runs out.
	table.insert(_connections, Workspace:GetAttributeChangedSignal("BoardingOpen"):Connect(function()
		if Workspace:GetAttribute("BoardingOpen") then return end

		local players = {}
		for player in pairs(_depositThreads) do
			table.insert(players, player)
		end

		for _, player in players do
			Local.CancelDeposit(player)
		end
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetupZone(part: Instance)
	if not part:IsA("BasePart") then return end

	part.CollisionGroup = "DepositZone"

	local zone = ZonePlus.new(part)

	zone.playerEntered:Connect(function(player: Player)
		Local.StartDeposit(player)
	end)

	zone.playerExited:Connect(function(player: Player)
		Local.CancelDeposit(player)
	end)

	_zones[part] = zone
end

function Local.RemoveZone(part: BasePart)
	local zone = _zones[part]
	if zone then
		zone:destroy()
		_zones[part] = nil
	end

	if part.Parent then
		part.CollisionGroup = "Default"
	end
end

function Local.StartDeposit(player: Player)
	if RoundService.GetState() ~= "InProgress" then return end
	if not Workspace:GetAttribute("BoardingOpen") then return end

	local character = player.Character
	if not character then return end

	if not character:GetAttribute("HasContraband") then return end
	if character:GetAttribute("Disabled") then return end
	if TeamService.GetTeam(player) ~= "Smuggler" then return end

	Local.CancelDeposit(player)

	_depositConnections[player] = character:GetAttributeChangedSignal("Disabled"):Connect(function()
		if character:GetAttribute("Disabled") then
			Local.CancelDeposit(player)
		end
	end)

	_depositThreads[player] = task.delay(DEPOSIT_TIME, function()
		Local.CompleteDeposit(player)
	end)
end

function Local.CancelDeposit(player: Player)
	if _depositThreads[player] then
		task.cancel(_depositThreads[player])
		_depositThreads[player] = nil
	end

	if _depositConnections[player] then
		_depositConnections[player]:Disconnect()
		_depositConnections[player] = nil
	end
end

function Local.CompleteDeposit(player: Player)
	_depositThreads[player] = nil
	if _depositConnections[player] then
		_depositConnections[player]:Disconnect()
		_depositConnections[player] = nil
	end

	if RoundService.GetState() ~= "InProgress" then return end
	if not Workspace:GetAttribute("BoardingOpen") then return end -- final guard; BoardingOpen watcher should already have cancelled this

	local record = JailService.GetRecord(player)
	if record and record.isJailed then return end

	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then return end

	if character:GetAttribute("Disabled") then return end
	if TeamService.GetTeam(player) ~= "Smuggler" then return end

	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return end

	local heldItem = character:FindFirstChild(heldItemName)
	if not heldItem or not heldItem:IsA("Model") then return end

	local starsDeposited = ItemService.GetContrabandRating(heldItem)
	local itemsDeposited = ItemService.GetContrabandItemCount(heldItem)

	ItemService.ConsumeEquipped(player)

	RoundService.AddToQuota(starsDeposited)

	if starsDeposited > 0 then
		RewardService.GrantTeamTaskReward(player, math.floor(starsDeposited * TOKENS_PER_STAR))

		DataService.UpdateData(player, {
			type = "UpdateProfile",
			data = { key = "totalValueSmuggled", amount = starsDeposited },
		})

		DataService.UpdateData(player, {
			type = "UpdateProfile",
			data = { key = "totalItemsSmuggled", amount = itemsDeposited },
		})
	end

	SpawnService.SpawnPlayer(player, player.Team and player.Team.Name or "Smuggler")
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, thread in _depositThreads do
		task.cancel(thread)
	end
	table.clear(_depositThreads)

	for _, conn in _depositConnections do
		conn:Disconnect()
	end
	table.clear(_depositConnections)

	for part, zone in _zones do
		zone:destroy()
	end
	table.clear(_zones)

	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)
end

return Shared