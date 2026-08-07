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

local _currentTargetCharacter: Model? = nil
local _activeHighlight: Highlight? = nil
local _holdingCharacter: Model? = nil
local _hasHandcuffsEquipped: boolean = false
local _promptCounter = 0

--|| Constants
local ARRESTABLE_TAG = "Arrestable"
local HANDCUFFS_ITEM_NAME = "Handcuffs"

local MAX_ARREST_DISTANCE = 8
local ARREST_TIME = 0.5

-- The OTS camera trails ~8 studs behind the character (see CameraController's CAMERA_OFFSET), so a
-- look-raycast from the camera needs far more reach than MAX_ARREST_DISTANCE (a character-to-target
-- distance) to ever land on a target standing right next to the player.
local LOOK_RAY_DISTANCE = 12

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Observers.observeTag(ARRESTABLE_TAG, function(character)
		task.spawn(Local.SetupPrompt, character)

		return function()
			task.spawn(Local.TeardownPrompt, character)
		end
	end)

	table.insert(_networkConnections, Network:BindEvent("Arrest", "Result", function(data: { result: string, reason: string? })
		Network:FireLocal("Arrest", "ResultReceived", data)
	end))

	_renderConn = RunService.RenderStepped:Connect(Local.OnRenderStepped)

	_stopCharacterObserver = Observers.observeLocalCharacter(function(character: Model)
		local stopAttribute = Observers.observeAttribute(character, "HeldItem", function(heldItemName)
			_hasHandcuffsEquipped = heldItemName == HANDCUFFS_ITEM_NAME

			if not _hasHandcuffsEquipped and _currentTargetCharacter then
				Local.OnTargetExited()
			end
		end)

		return function()
			stopAttribute()
			_hasHandcuffsEquipped = false
		end
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
-- Note: this sets up identically for a real Smuggler's character AND every crowd NPC (both carry the
-- "Arrestable" tag — see ArrestService/NpcService) — the prompt text and behavior here must stay
-- generic ("Passenger", not the target's real name) so which characters show a prompt never leaks who's
-- actually a Smuggler. Only the server knows that, on Complete.
function Local.SetupPrompt(character: Instance)
	if not character:IsA("Model") then return end
	if _activePrompts[character] then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
	if not hrp or not hrp:IsA("BasePart") then return end

	local promptId = character:GetAttribute("UID")
	if not promptId then
		_promptCounter += 1
		promptId = tostring(_promptCounter)
	end

	local prompt = ProximityPrompt.new({
		name = `Arrest_{promptId}`,
		actionText = "Arrest",
		objectText = "Passenger",
		holdDuration = ARREST_TIME,
		maxActivationDistance = MAX_ARREST_DISTANCE,
		enabled = false,
		keyboardKeyCode = Enum.KeyCode.E,
		gamepadKeyCode = Enum.KeyCode.ButtonX,
		parent = hrp,
	})

	prompt.HoldStarted:Connect(function()
		_holdingCharacter = character :: Model
		Network:FireServer("Arrest", "Start", { targetCharacter = character })
	end)

	prompt.HoldEnded:Connect(function()
		if _holdingCharacter == character then
			_holdingCharacter = nil
		end
	end)

	prompt.Triggered:Connect(function()
		Network:FireServer("Arrest", "Complete", { targetCharacter = character })
	end)

	_activePrompts[character :: Model] = prompt
end

function Local.TeardownPrompt(character: Instance)
	local prompt = _activePrompts[character :: Model]
	if not prompt then return end

	if _currentTargetCharacter == character then
		Local.OnTargetExited()
	end

	prompt:Destroy()
	_activePrompts[character :: Model] = nil
end

function Local.GetArrestTargetFromResult(result: RaycastResult): Model?
	local ancestor = result.Instance

	while ancestor do
		if ancestor:IsA("Model") and CollectionService:HasTag(ancestor, ARRESTABLE_TAG) then
			return ancestor :: Model
		end
		ancestor = ancestor.Parent
	end

	return nil
end

function Local.OnRenderStepped()
	if not RoundController.IsPlaying() or not _hasHandcuffsEquipped then
		if _currentTargetCharacter then Local.OnTargetExited() end
		return
	end

	-- Don't let look-based retargeting fight an in-progress hold — once the player commits to an
	-- arrest, only the prompt's own distance check (maxActivationDistance) should be able to cancel it.
	if _holdingCharacter and _holdingCharacter == _currentTargetCharacter then
		return
	end

	local CUSTOM_RAYPARAMS = RaycastParams.new()
	CUSTOM_RAYPARAMS.FilterDescendantsInstances = {player.Character}
	CUSTOM_RAYPARAMS.FilterType = Enum.RaycastFilterType.Exclude

	local result = CameraController.GetLookTarget(LOOK_RAY_DISTANCE, CUSTOM_RAYPARAMS)

	local newTarget: Model? = nil
	if result then
		newTarget = Local.GetArrestTargetFromResult(result)
	end

	if newTarget == _currentTargetCharacter then return end

	if _currentTargetCharacter then
		Local.OnTargetExited()
	end

	if newTarget then
		Local.OnTargetEntered(newTarget)
	end
end

function Local.OnTargetEntered(character: Model)
	_currentTargetCharacter = character
	_activeHighlight = Local.CreateHighlight(character)

	local prompt = _activePrompts[character]
	if prompt then
		prompt:SetEnabled(true)
	end
end

function Local.OnTargetExited()
	if _activeHighlight then
		_activeHighlight:Destroy()
		_activeHighlight = nil
	end

	if _currentTargetCharacter then
		local prompt = _activePrompts[_currentTargetCharacter]
		if prompt then
			prompt:SetEnabled(false)
		end
	end

	_currentTargetCharacter = nil
end

function Local.CreateHighlight(target: Instance): Highlight
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 60, 60)
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
