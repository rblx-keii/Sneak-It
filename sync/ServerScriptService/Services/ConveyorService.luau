--|| Services
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)

local NodeGraph = require(script.Parent.NpcService.NodeGraph)
local RoundService = require(script.Parent.RoundService)
local MapService = require(script.Parent.MapService)
local ItemService = require(script.Parent.ItemService)
local JailService = require(script.Parent.JailService)

--|| Types
type BeltItemInfo = {
	ownerId: number,
	startPos: Vector3,
	endPos: Vector3,
	startTime: number,
	travelTime: number,
}

--|| Variables
local _connections: {RBXScriptConnection} = {}
local _networkConnections: {Network.Cleanup} = {}

local _placePointConveyor: {[BasePart]: BasePart} = {}
local _taggedPlaceParts: {BasePart} = {}

local _beltItems: {[Model]: BeltItemInfo} = {}

local Local = {}
local Shared = {}

--|| Constants
local PLACE_ZONE_TAG = "ConveyorPlaceZone"
local MAX_INTERACT_DISTANCE = 10

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, RoundService.OnStateChange:Connect(Local.OnRoundStateChange))

	table.insert(_networkConnections, Network:BindEvent("Conveyor", "Place", function(player: Player, data: {node: BasePart}?)
		Local.TryPlaceItem(player, data and data.node)
	end))

	local currentState = RoundService.GetState()
	if currentState == "Starting" or currentState == "InProgress" then
		Local.SetupCheckpoints()
	end
end

function Shared.Start()

end

-- [[ Private Functions — Round lifecycle ]] --
function Local.OnRoundStateChange(newState: string)
	if newState == "Starting" then
		Local.SetupCheckpoints()
	elseif newState == "Ended" or newState == "Intermission" then
		Local.TeardownCheckpoints()
	end
end

function Local.SetupCheckpoints()
	Local.TeardownCheckpoints()

	local activeMap = MapService.GetActiveMap()
	if not activeMap then return end

	local nodesFolder = activeMap:FindFirstChild("Nodes")
	if not nodesFolder then return end

	for _, node in NodeGraph.EnumerateAllNodes(nodesFolder) do
		if not NodeGraph.IsConveyorNode(node) then continue end
		if not NodeGraph.GetPickupNode(node) then continue end

		local startSub = NodeGraph.GetSubNode(node, "Start")
		local placePart = startSub or node

		CollectionService:AddTag(placePart, PLACE_ZONE_TAG)
		_placePointConveyor[placePart] = node

		table.insert(_taggedPlaceParts, placePart)
	end
end

function Local.TeardownCheckpoints()
	for _, part in _taggedPlaceParts do
		CollectionService:RemoveTag(part, PLACE_ZONE_TAG)
	end
	table.clear(_taggedPlaceParts)

	table.clear(_placePointConveyor)

	for item in _beltItems do
		if item.Parent then
			item:Destroy()
		end
	end
	table.clear(_beltItems)
end

-- [[ Private Functions — Player belt transit ]] --
function Local.GetCharacterAndHrp(player: Player): (Model?, BasePart?)
	local character = player.Character
	if not character then return nil, nil end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return character, hrp
end

function Local.AreItemPartsWelded(item: Model): boolean
	local weldsFolder = item:FindFirstChild("ItemWelds")
	if not weldsFolder then return false end

	local primaryPart = item.PrimaryPart
	if not primaryPart then return false end

	for _, descendant in item:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= primaryPart then
			local weld = weldsFolder:FindFirstChild(`Weld_{descendant.Name}`) :: WeldConstraint?
			if not weld or weld.Part0 ~= primaryPart or weld.Part1 ~= descendant then
				return false
			end
		end
	end

	return true
end

function Local.RunBeltTransit(item: Model, info: BeltItemInfo)
	task.spawn(function()
		while true do
			if _beltItems[item] ~= info then return end

			-- Interactable is suppressed for the whole ride (see TryPlaceItem), so its absence no
			-- longer signals "someone already took it" — only destruction does.
			if not item.Parent then
				_beltItems[item] = nil
				return
			end

			local elapsed = workspace:GetServerTimeNow() - info.startTime
			local alpha = math.clamp(elapsed / info.travelTime, 0, 1)
			local primaryPart = item.PrimaryPart
			if primaryPart then
				primaryPart.CFrame = CFrame.new(info.startPos:Lerp(info.endPos, alpha))
			end

			if alpha >= 1 then
				item:SetAttribute("OnBelt", nil)

				for _, part in item:GetDescendants() do
					if part:IsA("BasePart") then
						part.Anchored = false
					end
				end

				-- Only pickup-able once it's actually reached the end of the belt.
				CollectionService:AddTag(item, "Interactable")

				_beltItems[item] = nil
				return
			end

			task.wait(0.1)
		end
	end)
end

function Local.TryPlaceItem(player: Player, placePart: BasePart?)
	if not placePart then return end

	local conveyorNode = _placePointConveyor[placePart]
	if not conveyorNode then return end

	local record = JailService.GetRecord(player)
	if not record or record.isJailed then return end

	local character, hrp = Local.GetCharacterAndHrp(player)
	if not character or not hrp then return end

	if (hrp.Position - placePart.Position).Magnitude > MAX_INTERACT_DISTANCE then return end

	local heldItemName = character:GetAttribute("HeldItem")
	if not heldItemName or heldItemName == "" then return end

	local pickupNode = NodeGraph.GetPickupNode(conveyorNode)
	if not pickupNode then return end

	local item = ItemService.ForceDropItem(character)
	if not item or not item.PrimaryPart then return end

	if not Local.AreItemPartsWelded(item) then
		warn(`[ConveyorService] TryPlaceItem({player.Name}) — {item.Name}'s parts aren't fully welded to its PrimaryPart, belt transit may look disjointed`)
	end

	-- ForceDropItem (ClearEquipped) tags it Interactable like any normal world-dropped item —
	-- suppress that while it's riding the belt so it can't be snatched off mid-transit. Restored in
	-- RunBeltTransit once it actually reaches the end.
	CollectionService:RemoveTag(item, "Interactable")

	local startSub = NodeGraph.GetSubNode(conveyorNode, "Start")
	local endSub = NodeGraph.GetSubNode(conveyorNode, "End")
	local startPos = startSub and NodeGraph.GetNodePosition(startSub) or NodeGraph.GetNodePosition(conveyorNode)
	local endPos = endSub and NodeGraph.GetNodePosition(endSub) or NodeGraph.GetNodePosition(pickupNode)

	item:SetAttribute("OwnerUserId", player.UserId)
	item:SetAttribute("OnBelt", true)

	-- Matches ProjectileSimulation's multi-part handling (see Local.InstantiateBullet) and the same
	-- fix in NpcService's belt transit: only the PrimaryPart is anchored and CFrame-driven; welded
	-- descendants stay unanchored so their WeldConstraint physically drags them along. PivotTo-ing the
	-- whole assembly here — after ClearEquipped had already left every part unanchored — was leaving
	-- non-primary parts stuck at their stale in-hand offset for the entire ride.
	local primaryPart = item.PrimaryPart :: BasePart
	for _, part in item:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = part == primaryPart
		end
	end

	primaryPart.CFrame = CFrame.new(startPos)

	local info: BeltItemInfo = {
		ownerId = player.UserId,
		startPos = startPos,
		endPos = endPos,
		startTime = workspace:GetServerTimeNow(),
		travelTime = NPCConfig.BELT_TRAVEL_TIME,
	}
	_beltItems[item] = info

	item.Destroying:Once(function()
		_beltItems[item] = nil
	end)

	Local.RunBeltTransit(item, info)
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	Local.TeardownCheckpoints()
end

return Shared
