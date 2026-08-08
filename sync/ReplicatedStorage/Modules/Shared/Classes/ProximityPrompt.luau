--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--|| References
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)
local InputController = require(ReplicatedStorage.Modules.Shared.InputController)
local RadialProgress = require(script.Parent.RadialProgress)

local Prompt = ReplicatedStorage.Assets.Prompt
if not Prompt then
	warn("ProximityPrompt asset not found in ReplicatedStorage.Assets")
	return nil
end

local LocalPlayer = Players.LocalPlayer

--|| Constants
local CAS_ACTION_PREFIX = "ProximityPrompt_"
local PROMPT_PRIORITY = Enum.ContextActionPriority.High.Value + 1

-- Click feedback: Content (and the ring alongside it) punches down then springs
-- back while the ring holds at 100%
local COMPLETION_PUNCH_DOWN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COMPLETION_PUNCH_UP_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local COMPLETION_PUNCH_SCALE = 0.85
local COMPLETION_RESET_DELAY = 0.24 -- matches punch down + up duration
local COMPLETION_RESET_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- Ring's Container isn't a descendant of Content, so its own UIScale needs to be
-- punched in parallel to stay visually in sync with Content's.
local function PunchScale(scale: UIScale?)
	if not scale then return end

	local punchDown = TweenService:Create(scale, COMPLETION_PUNCH_DOWN_INFO, {Scale = COMPLETION_PUNCH_SCALE})
	punchDown.Completed:Once(function()
		TweenService:Create(scale, COMPLETION_PUNCH_UP_INFO, {Scale = 1}):Play()
	end)
	punchDown:Play()
end

--|| Types
export type PromptSettings = {
	name: string,
	actionText: string,
	objectText: string,
	holdDuration: number,
	maxActivationDistance: number,
	enabled: boolean,
	keyboardKeyCode: Enum.KeyCode,
	gamepadKeyCode: Enum.KeyCode,
	parent: Instance,
}

local ProximityPrompt = {}
ProximityPrompt.__index = ProximityPrompt

export type ClassType = typeof(setmetatable({} :: {
	-- || Properties
	_settings: PromptSettings,
	_instanceId: number,

	-- Signals
	Triggered: typeof(ModuleUtils.signal.new()),
	HoldStarted: typeof(ModuleUtils.signal.new()),
	HoldEnded: typeof(ModuleUtils.signal.new()),

	-- UI
	_prompt: BillboardGui,
	_radialProgress: RadialProgress.ClassType,
	_actionLabel: TextLabel,
	_objectLabel: TextLabel,
	_keyLabel: TextLabel,
	_buttonActivator: TextButton,
	_contentScale: UIScale?, -- Drives the click-punch feedback, lives on the Content frame

	-- State
	_isHolding: boolean,
	_isVisible: boolean,
	_isEnabled: boolean,
	_isSuppressed: boolean, -- True while another prompt is being held
	_currentProgress: number, -- Replaced _holdStart
	_isCompleting: boolean, -- True while the completion punch anim is holding the ring at 100%

	-- Connections
	_heartbeatConn: RBXScriptConnection?,
	_btnDownConn: RBXScriptConnection?,
	_btnUpConn: RBXScriptConnection?,
	_externalBtnConns: {RBXScriptConnection},
	_actionHandle: any, -- InputController handle
	_resetThread: thread?,

	-- || Public Methods
	BindExternalButton: (self: ClassType, button: GuiButton) -> (),
	SetEnabled: (self: ClassType, state: boolean) -> (),
	UpdateSettings: (self: ClassType, newSettings: {[string]: any}) -> (),
	Destroy: (self: ClassType) -> (),

	-- || Private Methods
	_GetActionName: (self: ClassType) -> string,
	_BindInput: (self: ClassType) -> (),
	_UnbindInput: (self: ClassType) -> (),
	_StartHeartbeat: (self: ClassType) -> (),
	_OnHeartbeat: (self: ClassType, dt: number) -> (),
	_CheckDistance: (self: ClassType) -> boolean,
	_SetVisible: (self: ClassType, state: boolean) -> (),
	_UpdateProgressBar: (self: ClassType, progress: number) -> (),
	_StartHold: (self: ClassType) -> (),
	_StopHold: (self: ClassType, completed: boolean) -> (),
	_PlayCompletionAnimation: (self: ClassType) -> (),
}, ProximityPrompt))

-- All live instances, so holding one prompt can suppress every other one on screen
local _instances: {[ClassType]: true} = {}

-- Guarantees a unique CAS action name per instance — settings.name alone can collide (e.g. sibling parts sharing a name), silently stealing the CAS binding from an earlier prompt.
local _nextInstanceId = 0

local function SetOthersSuppressed(activeSelf: ClassType, state: boolean)
	for instance in _instances do
		if instance ~= activeSelf then
			instance._isSuppressed = state
		end
	end
end

-- [[ Private Helpers ]] --
local function GetLocalHRP(): BasePart?
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart
end

local function GetParentPosition(parent: Instance): Vector3?
	if parent:IsA("BasePart") then
		return (parent :: BasePart).Position
	elseif parent:IsA("Model") then
		local pivot = (parent :: Model):GetPivot()
		return pivot.Position
	elseif parent:IsA("Attachment") then
		return (parent :: Attachment).WorldPosition
	end
	return nil
end

--|| MAIN ||--

--/ Constructs and returns a new ProximityPrompt instance
function ProximityPrompt.new(settings: PromptSettings): ClassType
	local self = setmetatable({} :: any, ProximityPrompt) :: ClassType

	_nextInstanceId += 1
	self._instanceId = _nextInstanceId

	self._settings = settings
	self._isHolding = false
	self._isVisible = false
	self._isEnabled = settings.enabled
	self._isSuppressed = false
	self._currentProgress = 0
	self._isCompleting = false
	self._resetThread = nil
	self._externalBtnConns = {}

	self.Triggered = ModuleUtils.signal.new()
	self.HoldStarted = ModuleUtils.signal.new()
	self.HoldEnded = ModuleUtils.signal.new()

	local promptClone = Prompt:Clone() :: BillboardGui
	promptClone.Adornee = settings.parent
	promptClone.Enabled = false
	promptClone.Parent = settings.parent

	self._prompt = promptClone
	self._actionLabel = promptClone:FindFirstChild("ActionText", true) :: TextLabel
	self._objectLabel = promptClone:FindFirstChild("ObjectText", true) :: TextLabel
	self._keyLabel = promptClone:FindFirstChild("Label", true) :: TextLabel
	self._buttonActivator = promptClone:FindFirstChild("ButtonActivator", true) :: TextButton

	local keyFrame = promptClone:FindFirstChild("Key", true) :: Frame
	local contentFrame = keyFrame:FindFirstChild("Content") :: Frame

	self._radialProgress = RadialProgress.new(contentFrame, {
		Color = Color3.new(1, 1, 1),
		Thickness = 0.05,
	})
	
	self._contentScale = contentFrame:FindFirstChildOfClass("UIScale")
	
	self._actionLabel.Text = settings.actionText
	self._objectLabel.Text = settings.objectText
	self._keyLabel.Text = settings.keyboardKeyCode.Name

	self:_UpdateProgressBar(0)

	self._BindInput(self)
	self._StartHeartbeat(self)

	_instances[self] = true

	return self
end

-- [[ Private Methods ]] --
function ProximityPrompt._GetActionName(self: ClassType): string
	return `{CAS_ACTION_PREFIX}{self._settings.name}_{self._instanceId}`
end

function ProximityPrompt._BindInput(self: ClassType)
	local actionName = self._GetActionName(self)

	self._actionHandle = InputController.BindAction({
		name = actionName,
		keys = { self._settings.keyboardKeyCode, self._settings.gamepadKeyCode },
		priority = PROMPT_PRIORITY,
		callback = function(_name: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult?
			if not self._isEnabled or not self._isVisible then
				return Enum.ContextActionResult.Pass
			end

			if inputState == Enum.UserInputState.Begin then
				self._StartHold(self)
			elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
				self._StopHold(self, false)
			end

			return Enum.ContextActionResult.Sink
		end
	})

	self._btnDownConn = self._buttonActivator.MouseButton1Down:Connect(function()
		if not self._isEnabled or not self._isVisible then return end
		self._StartHold(self)
	end)

	self._btnUpConn = self._buttonActivator.MouseButton1Up:Connect(function()
		if self._isHolding then
			self._StopHold(self, false)
		end
	end)
end

function ProximityPrompt._UnbindInput(self: ClassType)
	if self._actionHandle then
		self._actionHandle:Unbind()
		self._actionHandle = nil
	end

	if self._btnDownConn then
		self._btnDownConn:Disconnect()
		self._btnDownConn = nil
	end

	if self._btnUpConn then
		self._btnUpConn:Disconnect()
		self._btnUpConn = nil
	end

	for _, conn in self._externalBtnConns do
		conn:Disconnect()
	end
	table.clear(self._externalBtnConns)
end

function ProximityPrompt._StartHeartbeat(self: ClassType)
	self._heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		self._OnHeartbeat(self, dt)
	end)
end

function ProximityPrompt._OnHeartbeat(self: ClassType, dt: number)
	local inRange = self._CheckDistance(self)

	if inRange and self._isEnabled and not self._isSuppressed then
		if not self._isVisible then
			self._SetVisible(self, true)
		end
	else
		if self._isVisible then
			self._SetVisible(self, false)
		end

		if self._isHolding then
			self._StopHold(self, false)
		end

		-- Immediately zero out progress if we walk out of range
		if self._resetThread then
			task.cancel(self._resetThread)
			self._resetThread = nil
		end
		self._isCompleting = false
		if self._currentProgress > 0 then
			self._currentProgress = 0
			self._UpdateProgressBar(self, 0)
		end
		return
	end

	-- Continuously update progress: Increment if holding, Decrement if released.
	-- Held at 100% (skipped here) while the completion punch anim plays out.
	if self._isHolding then
		self._currentProgress += (dt / self._settings.holdDuration)
	elseif not self._isCompleting and self._currentProgress > 0 then
		self._currentProgress -= (dt / self._settings.holdDuration)
	end

	self._currentProgress = math.clamp(self._currentProgress, 0, 1)
	self._UpdateProgressBar(self, self._currentProgress)

	if self._isHolding and self._currentProgress >= 1 then
		self._StopHold(self, true)
	end
end

function ProximityPrompt._CheckDistance(self: ClassType): boolean
	local hrp = GetLocalHRP()
	if not hrp then return false end

	local targetPos = GetParentPosition(self._settings.parent)
	if not targetPos then return false end

	return (hrp.Position - targetPos).Magnitude <= self._settings.maxActivationDistance
end

function ProximityPrompt._SetVisible(self: ClassType, state: boolean)
	self._isVisible = state
	self._prompt.Enabled = state

	if not state then
		self._currentProgress = 0
		self._UpdateProgressBar(self, 0)
	end
end

function ProximityPrompt._UpdateProgressBar(self: ClassType, progress: number)
	self._radialProgress:SetProgress(progress)
end

function ProximityPrompt._StartHold(self: ClassType)
	if self._isHolding then return end

	-- A fresh hold overrides any pending completion reset from a prior trigger
	if self._resetThread then
		task.cancel(self._resetThread)
		self._resetThread = nil
	end
	self._isCompleting = false

	self._isHolding = true
	self.HoldStarted:Fire()
	SetOthersSuppressed(self, true)
end

function ProximityPrompt._StopHold(self: ClassType, completed: boolean)
	if not self._isHolding then return end
	self._isHolding = false

	self.HoldEnded:Fire()
	SetOthersSuppressed(self, false)

	if completed then
		self._PlayCompletionAnimation(self)
		self.Triggered:Fire()
	end
end

function ProximityPrompt._PlayCompletionAnimation(self: ClassType)
	self._isCompleting = true

	PunchScale(self._contentScale)
	PunchScale(self._radialProgress.Scale)

	-- Hold the ring at 100% through the punch, then ease it back down to 0
	self._resetThread = task.delay(COMPLETION_RESET_DELAY, function()
		self._resetThread = nil
		self._isCompleting = false
		self._currentProgress = 0
		self._radialProgress:TweenProgress(0, COMPLETION_RESET_TWEEN_INFO)
	end)
end

-- [[ Public Methods ]] --

-- Routes a single external button (e.g. a mobile "Prompt Helper" button) to whichever prompt
-- instance is currently visible+enabled, resolved fresh on each press — unlike BindExternalButton,
-- this isn't tied to one instance since only one prompt is ever meant to be on screen at a time.
function ProximityPrompt.BindGlobalExternalButton(button: GuiButton): () -> ()
	local activeInstance: ClassType? = nil

	local function findActiveInstance(): ClassType?
		for instance in _instances do
			if instance._isEnabled and instance._isVisible then
				return instance
			end
		end
		return nil
	end

	local downConn = button.MouseButton1Down:Connect(function()
		local instance = findActiveInstance()
		if not instance then return end
		activeInstance = instance
		instance._StartHold(instance)
	end)

	local upConn = button.MouseButton1Up:Connect(function()
		if not activeInstance then return end
		activeInstance._StopHold(activeInstance, false)
		activeInstance = nil
	end)

	local leaveConn = button.MouseLeave:Connect(function()
		if not activeInstance then return end
		activeInstance._StopHold(activeInstance, false)
		activeInstance = nil
	end)

	return function()
		downConn:Disconnect()
		upConn:Disconnect()
		leaveConn:Disconnect()
		if activeInstance then
			activeInstance._StopHold(activeInstance, false)
			activeInstance = nil
		end
	end
end

function ProximityPrompt.BindExternalButton(self: ClassType, button: GuiButton)
	table.insert(self._externalBtnConns, button.MouseButton1Down:Connect(function()
		if not self._isEnabled or not self._isVisible then return end
		self._StartHold(self)
	end))

	table.insert(self._externalBtnConns, button.MouseButton1Up:Connect(function()
		if self._isHolding then self._StopHold(self, false) end
	end))

	table.insert(self._externalBtnConns, button.MouseLeave:Connect(function()
		if self._isHolding then self._StopHold(self, false) end
	end))
end

function ProximityPrompt.SetEnabled(self: ClassType, state: boolean)
	self._isEnabled = state

	if not state then
		self._SetVisible(self, false)
		self._StopHold(self, false)
	end
end

function ProximityPrompt.UpdateSettings(self: ClassType, newSettings: {[string]: any})
	for key, value in newSettings do
		self._settings[key] = value
	end
	
	if newSettings.actionText then
		self._actionLabel.Text = newSettings.actionText
	end
	if newSettings.objectText then
		self._objectLabel.Text = newSettings.objectText
	end
	if newSettings.keyboardKeyCode then
		self._keyLabel.Text = (newSettings.keyboardKeyCode :: Enum.KeyCode).Name

		-- Rebind CAS with new key
		self._UnbindInput(self)
		self._BindInput(self)
	end
end

function ProximityPrompt.Destroy(self: ClassType)
	_instances[self] = nil

	if self._resetThread then
		task.cancel(self._resetThread)
		self._resetThread = nil
	end

	self._StopHold(self, false)
	self._UnbindInput(self)

	if self._heartbeatConn then
		self._heartbeatConn:Disconnect()
		self._heartbeatConn = nil
	end

	if self._radialProgress then
		self._radialProgress:Destroy()
	end

	if self._prompt and self._prompt.Parent then
		self._prompt:Destroy()
	end

	self.Triggered:DisconnectAll()
	self.HoldStarted:DisconnectAll()
	self.HoldEnded:DisconnectAll()
end

return ProximityPrompt