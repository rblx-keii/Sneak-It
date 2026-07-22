--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ProximityPrompt = require(ReplicatedStorage.Modules.Shared.Classes.ProximityPrompt)

local player = Players.LocalPlayer

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _tagConnections: {RBXScriptConnection} = {}
local _activePrompts: {[Model]: ProximityPrompt.ClassType} = {}

--|| Constants
local STEALABLE_TAG = "StealableNPC"

local MAX_STEAL_DISTANCE = 8
local DEFAULT_STEAL_THRESHOLD = 3

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	for _, npc in CollectionService:GetTagged(STEALABLE_TAG) do
		Local.SetupPrompt(npc)
	end

	table.insert(_tagConnections, CollectionService:GetInstanceAddedSignal(STEALABLE_TAG):Connect(Local.SetupPrompt))
	table.insert(_tagConnections, CollectionService:GetInstanceRemovedSignal(STEALABLE_TAG):Connect(Local.TeardownPrompt))

	table.insert(_networkConnections, Network:BindEvent("Steal", "Result", function(data: { result: string, reason: string? })
		Network:FireLocal("Steal", "ResultReceived", data)
	end))
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetupPrompt(npc: Instance)
	if not npc:IsA("Model") then return end
	if _activePrompts[npc] then return end

	local hrp = npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then return end

	local npcId = npc:GetAttribute("UID")

	local threshold = npc:GetAttribute("StealThreshold")
	if type(threshold) ~= "number" or threshold <= 0 then
		threshold = DEFAULT_STEAL_THRESHOLD
	end

	local prompt = ProximityPrompt.new({
		name = `Steal_{npcId or npc.Name}`,
		actionText = "Steal Bag",
		objectText = npc.Name,
		holdDuration = threshold,
		maxActivationDistance = MAX_STEAL_DISTANCE,
		enabled = true,
		keyboardKeyCode = Enum.KeyCode.E,
		gamepadKeyCode = Enum.KeyCode.ButtonX,
		parent = hrp,
	})

	prompt.HoldStarted:Connect(function()
		Network:FireServer("Steal", "Start", { npcId = npcId })
	end)
	
	prompt.Triggered:Connect(function()
		Network:FireServer("Steal", "Complete", { npcId = npcId })
	end)

	_activePrompts[npc :: Model] = prompt
end

function Local.TeardownPrompt(npc: Instance)
	local prompt = _activePrompts[npc :: Model]
	if not prompt then return end

	prompt:Destroy()
	_activePrompts[npc :: Model] = nil
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	for _, conn in _tagConnections do
		conn:Disconnect()
	end
	table.clear(_tagConnections)

	for _, conn in _networkConnections do
		conn:Disconnect()
	end
	table.clear(_networkConnections)

	for _, prompt in _activePrompts do
		prompt:Destroy()
	end
	table.clear(_activePrompts)
end

return Shared