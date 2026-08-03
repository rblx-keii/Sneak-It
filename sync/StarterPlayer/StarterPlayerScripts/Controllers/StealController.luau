--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--|| References
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)
local Network = require(ReplicatedStorage.Modules.Network)
local ProximityPrompt = require(ReplicatedStorage.Modules.Shared.Classes.ProximityPrompt)

local CameraController = require(script.Parent.CameraController)
local RoundController = require(script.Parent.RoundController)

local player = Players.LocalPlayer

--|| Variables
local _networkConnections: {Network.Cleanup} = {}
local _tagConnections: {RBXScriptConnection} = {}
local _activePrompts: {[Model]: ProximityPrompt.ClassType} = {}

local _renderConn: RBXScriptConnection? = nil
local _stopCharacterObserver: (() -> ())? = nil

local _currentTargetNpc: Model? = nil
local _activeHighlight: Highlight? = nil
local _holdingNpc: Model? = nil
local _isHoldingBag: boolean = false

--|| Constants
local STEALABLE_TAG = "StealableNPC"

local MAX_STEAL_DISTANCE = 8
local DEFAULT_STEAL_THRESHOLD = 3

-- The OTS camera trails ~8 studs behind the character (see CameraController's CAMERA_OFFSET), so a
-- look-raycast from the camera needs far more reach than MAX_STEAL_DISTANCE (a character-to-NPC
-- distance) to ever land on a target standing right next to the player.
local LOOK_RAY_DISTANCE = 12

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Observers.observeTag(STEALABLE_TAG, function(npc)
		task.spawn(Local.SetupPrompt, npc)

		return function()
			task.spawn(Local.TeardownPrompt, npc)
		end
	end)

	table.insert(_networkConnections, Network:BindEvent("Steal", "Result", function(data: { result: string, reason: string? })
		Network:FireLocal("Steal", "ResultReceived", data)
	end))

	_renderConn = RunService.RenderStepped:Connect(Local.OnRenderStepped)

	_stopCharacterObserver = Observers.observeLocalCharacter(function(character: Model)
		local stopAttribute = Observers.observeAttribute(character, "HeldItem", function(heldItemName)
			local heldItem: Instance? = nil
			if heldItemName and heldItemName ~= "" then
				heldItem = character:FindFirstChild(heldItemName)
			end
			_isHoldingBag = heldItem ~= nil and heldItem:GetAttribute("IsBag") == true

			if _isHoldingBag and _currentTargetNpc then
				Local.OnTargetExited()
			end
		end)

		return function()
			stopAttribute()
			_isHoldingBag = false
		end
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetupPrompt(npc: Instance)
	if not npc:IsA("Model") then return end
	if _activePrompts[npc] then return end

	local hrp = npc:FindFirstChild("HumanoidRootPart") or npc:WaitForChild("HumanoidRootPart", 5)
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
		enabled = false,
		keyboardKeyCode = Enum.KeyCode.E,
		gamepadKeyCode = Enum.KeyCode.ButtonX,
		parent = hrp,
	})

	prompt.HoldStarted:Connect(function()
		_holdingNpc = npc :: Model
		Network:FireServer("Steal", "Start", { npcId = npcId })
	end)

	prompt.HoldEnded:Connect(function()
		if _holdingNpc == npc then
			_holdingNpc = nil
		end
	end)

	prompt.Triggered:Connect(function()
		Network:FireServer("Steal", "Complete", { npcId = npcId })
	end)

	_activePrompts[npc :: Model] = prompt
end

function Local.TeardownPrompt(npc: Instance)
	local prompt = _activePrompts[npc :: Model]
	if not prompt then return end

	if _currentTargetNpc == npc then
		Local.OnTargetExited()
	end

	prompt:Destroy()
	_activePrompts[npc :: Model] = nil
end

function Local.GetBagTargetFromResult(result: RaycastResult): (Model?, Model?)
	local ancestor = result.Instance
	local npc: Model? = nil

	while ancestor do
		if ancestor:IsA("Model") and CollectionService:HasTag(ancestor, STEALABLE_TAG) then
			npc = ancestor :: Model
			break
		end
		ancestor = ancestor.Parent
	end

	if not npc then
		return nil, nil
	end

	local heldItemName = npc:GetAttribute("HeldItem")
	local bagModel: Model? = nil
	if heldItemName and heldItemName ~= "" then
		bagModel = npc:FindFirstChild(heldItemName) :: Model?
	end

	if not bagModel then
		return nil, nil
	end

	return bagModel, npc
end

function Local.OnRenderStepped()
	if not RoundController.IsPlaying() or _isHoldingBag then
		if _currentTargetNpc then Local.OnTargetExited() end
		return
	end

	-- Don't let look-based retargeting fight an in-progress hold — once the player commits to a steal,
	-- only the prompt's own distance check (maxActivationDistance) should be able to cancel it.
	if _holdingNpc and _holdingNpc == _currentTargetNpc then
		return
	end

	local CUSTOM_RAYPARAMS = RaycastParams.new()
	CUSTOM_RAYPARAMS.FilterDescendantsInstances = {player.Character}
	CUSTOM_RAYPARAMS.FilterType = Enum.RaycastFilterType.Exclude

	local result = CameraController.GetLookTarget(LOOK_RAY_DISTANCE, CUSTOM_RAYPARAMS)

	local newBag: Model? = nil
	local newNpc: Model? = nil
	if result then
		newBag, newNpc = Local.GetBagTargetFromResult(result)
	end

	if newNpc == _currentTargetNpc then return end

	if _currentTargetNpc then
		Local.OnTargetExited()
	end

	if newNpc then
		Local.OnTargetEntered(newNpc, newBag :: Model)
	end
end

function Local.OnTargetEntered(npc: Model, bag: Model)
	_currentTargetNpc = npc
	_activeHighlight = Local.CreateHighlight(bag)

	local prompt = _activePrompts[npc]
	if prompt then
		prompt:SetEnabled(true)
	end
end

function Local.OnTargetExited()
	if _activeHighlight then
		_activeHighlight:Destroy()
		_activeHighlight = nil
	end

	if _currentTargetNpc then
		local prompt = _activePrompts[_currentTargetNpc]
		if prompt then
			prompt:SetEnabled(false)
		end
	end

	_currentTargetNpc = nil
end

function Local.CreateHighlight(target: Instance): Highlight
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineTransparency = 0
	highlight.Adornee = target :: PVInstance
	highlight.Parent = target
	return highlight
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

	if _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end

	if _stopCharacterObserver then
		_stopCharacterObserver()
		_stopCharacterObserver = nil
	end

	Local.OnTargetExited()

	for _, prompt in _activePrompts do
		prompt:Destroy()
	end
	table.clear(_activePrompts)
end

return Shared