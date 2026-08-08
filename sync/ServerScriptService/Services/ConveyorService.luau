--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local NPCConfig = require(ReplicatedStorage.Modules.Configs.NPCConfig)
local ItemsConfig = require(ReplicatedStorage.Modules.Configs.ItemsConfig)

local NodeGraph = require(script.Parent.NpcService.NodeGraph)
local RoundService = require(script.Parent.RoundService)
local MapService = require(script.Parent.MapService)
local ItemService = require(script.Parent.ItemService)
local JailService = require(script.Parent.JailService)
local TeamService = require(script.Parent.TeamService)

--|| Types
type BeltItemInfo = {
	ownerId: number,
	conveyorNode: BasePart,
	startPos: Vector3,
	endPos: Vector3,
	startTime: number,
	travelTime: number,
	indicatorFlashed: boolean,
	rotation: CFrame,
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

-- Matches ScannerWand's green/red scan-result colors, so every TSA scan surface reads consistently.
local INDICATOR_CLEAN_COLOR = Color3.fromRGB(60, 220, 90)
local INDICATOR_CONTRABAND_COLOR = Color3.fromRGB(220, 50, 50)
local INDICATOR_RESET_DELAY = 2

local CONTRABAND_FLAG_ATTR = "ContrabandFlagged"
local PICKUP_HIGHLIGHT_DURATION = 4 -- seconds the carrying player stays highlighted on TSA clients after pickup (see HighlightController)

-- Flip off once the "Indicator doesn't flash" investigation is done.
local DEBUG_INDICATOR = false

--|| MAIN ||--

-- [[ Startup ]] --
function Shared.Init()
	table.insert(_connections, RoundService.OnStateChange:Connect(Local.OnRoundStateChange))

	table.insert(_networkConnections, Network:BindEvent("Conveyor", "Place", function(player: Player, data: {node: BasePart}?)
		Local.TryPlaceItem(player, data and data.node)
	end))

	table.insert(_connections, ItemService.OnItemEquipped:Connect(Local.OnItemEquipped))

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

function Local.GetTsaPlayers(): {Player}
	local tsaPlayers = {}
	for _, player in Players:GetPlayers() do
		if TeamService.GetTeam(player) == "TSA" then
			table.insert(tsaPlayers, player)
		end
	end
	return tsaPlayers
end

-- TSA-only (see HighlightController — client-created Highlights don't replicate, so only whoever
-- receives the event ever sees it), so a flagged bag/carrier doesn't out itself to Smugglers.
function Local.BroadcastHighlight(action: "Start" | "Stop", target: Model)
	for _, tsaPlayer in Local.GetTsaPlayers() do
		Network:FireClient("Highlight", tsaPlayer, action, { targetCharacter = target })
	end
end

-- Runs the actual X-ray "scan" — the Indicator light flash is purely cosmetic (see below) and is
-- allowed to no-op if it's missing/misconfigured, but the scan result itself (flagging + highlighting
-- a contraband bag for TSA) always runs regardless of whether that light is set up.
function Local.ScanItem(conveyorNode: BasePart, item: Model): boolean
	local hasContraband = ItemService.GetContrabandItemCount(item) > 0

	if hasContraband and not item:GetAttribute(CONTRABAND_FLAG_ATTR) then
		item:SetAttribute(CONTRABAND_FLAG_ATTR, true)
		Local.BroadcastHighlight("Start", item)
	end

	Local.FlashIndicatorLight(conveyorNode, hasContraband)

	return hasContraband
end

-- Flashes the conveyor's "Indicator" model (an ObjectValue on the node — see NodeGraph.GetIndicatorModel)
-- red/green based on the scan result.
function Local.FlashIndicatorLight(conveyorNode: BasePart, hasContraband: boolean)
	local indicatorModel = NodeGraph.GetIndicatorModel(conveyorNode)
	if not indicatorModel then
		if DEBUG_INDICATOR then
			warn(`[ConveyorService][Debug] FlashIndicatorLight({conveyorNode:GetFullName()}) — no "Indicator" ObjectValue found on the node (or its Value isn't a Model)`)
		end
		return
	end

	local primaryPart = indicatorModel.PrimaryPart
	if not primaryPart then
		if DEBUG_INDICATOR then
			warn(`[ConveyorService][Debug] FlashIndicatorLight({conveyorNode:GetFullName()}) — Indicator model "{indicatorModel:GetFullName()}" has no PrimaryPart set`)
		end
		return
	end

	local originalColor = primaryPart:GetAttribute("OriginalColor")
	if typeof(originalColor) ~= "Color3" then
		originalColor = primaryPart.Color
		primaryPart:SetAttribute("OriginalColor", originalColor)
	end

	primaryPart.Color = hasContraband and INDICATOR_CONTRABAND_COLOR or INDICATOR_CLEAN_COLOR

	task.delay(INDICATOR_RESET_DELAY, function()
		if primaryPart and primaryPart.Parent then
			primaryPart.Color = originalColor
		end
	end)
end

-- Once a flagged bag is actually picked up, the standalone bag highlight is redundant (it's now
-- welded to a moving character) — swap it for a bounded "spotted" pulse on the carrying player.
function Local.OnItemEquipped(_player: Player, character: Model, item: Model)
	if not item:GetAttribute(CONTRABAND_FLAG_ATTR) then return end

	Local.BroadcastHighlight("Stop", item)
	Local.BroadcastHighlight("Start", character)

	task.delay(PICKUP_HIGHLIGHT_DURATION, function()
		Local.BroadcastHighlight("Stop", character)
	end)
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
				primaryPart.CFrame = info.rotation + info.startPos:Lerp(info.endPos, alpha)
			end

			if not info.indicatorFlashed and alpha >= 0.35 then
				info.indicatorFlashed = true
				Local.ScanItem(info.conveyorNode, item)
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

-- Items that don't sit right on the belt in their default orientation (e.g. Suitcase, which is too
-- tall standing up) declare a corrective properties.conveyorOrientation — an absolute, position-less
-- CFrame, found by rotating the item in Studio until it lies flat and reading the pivot back with
-- :GetPivot():ToOrientation(). Applied unconditionally whenever an item's config declares one, since
-- that's already a deliberate per-item decision, not something to re-derive from geometry at runtime.
-- Returned rotation-only (not combined with a position) since RunBeltTransit needs to keep
-- re-applying it every tick.
function Local.GetConveyorRotation(item: Model): CFrame
	local itemConfig = ItemsConfig.GetItem(item.Name)
	local conveyorOrientation = itemConfig and itemConfig.properties.conveyorOrientation :: CFrame?
	return conveyorOrientation or CFrame.identity
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

	local conveyorRotation = Local.GetConveyorRotation(item)
	primaryPart.CFrame = conveyorRotation + startPos

	local info: BeltItemInfo = {
		ownerId = player.UserId,
		conveyorNode = conveyorNode,
		startPos = startPos,
		endPos = endPos,
		startTime = workspace:GetServerTimeNow(),
		travelTime = NPCConfig.BELT_TRAVEL_TIME,
		indicatorFlashed = false,
		rotation = conveyorRotation,
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
