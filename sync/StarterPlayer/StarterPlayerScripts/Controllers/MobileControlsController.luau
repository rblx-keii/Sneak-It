--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

--|| References
local InputController = require(ReplicatedStorage.Modules.Shared.InputController)
local ProximityPrompt = require(ReplicatedStorage.Modules.Shared.Classes.ProximityPrompt)
local PlayerDataTemplate = require(ReplicatedStorage.Modules.PlayerDataTemplate)

local GuiController = require(script.Parent.GuiController)
local CameraController = require(script.Parent.CameraController)
local DataController = require(script.Parent.DataController)
local RoundController = require(script.Parent.RoundController)
local Hotbar = require(script.Parent.Gui.Hotbar)

local PlayerControls = require(script.Parent.Parent.PlayerModule):GetControls()

local Gui = GuiController.Guis.MobileControls

local movementJoystick = Gui:FindFirstChild("Movement Joystick") :: Frame
local cameraJoystick = Gui:FindFirstChild("Camera Joystick") :: Frame
local sprintButton = Gui:FindFirstChild("Sprint") :: Frame
local promptButton = Gui:FindFirstChild("Prompt") :: Frame
local pickupButton = Gui:FindFirstChild("Pickup") :: Frame
local throwButton = Gui:FindFirstChild("Throw") :: Frame
local switchButton = Gui:FindFirstChild("Switch") :: Frame
local dropButton = Gui:FindFirstChild("Drop") :: Frame
local popButton = Gui:FindFirstChild("Pop") :: Frame
local useButton = Gui:FindFirstChild("Use") :: Frame
local freeLookButton = Gui:FindFirstChild("FreeLook") :: Frame
local jumpButton = Gui:FindFirstChild("Jump") :: Frame

local activeHighlight = Gui:FindFirstChild("ActiveHighlight") :: Frame
local backgroundImage = Gui:FindFirstChild("Background") :: ImageLabel
local editorFrame = Gui:FindFirstChild("Editor") :: Frame
local editorDrag = editorFrame:FindFirstChild("Drag") :: Frame
local editorContent = editorFrame:FindFirstChild("Content") :: Frame
local sizeRow = editorContent:FindFirstChild("Size") :: Frame
local lockRow = editorContent:FindFirstChild("Lock") :: Frame
local enabledRow = editorContent:FindFirstChild("Enabled") :: Frame
local transparencyRow = editorContent:FindFirstChild("Transparency") :: Frame
local buttonsRow = editorContent:FindFirstChild("Buttons") :: Frame
local selectedLabel = editorContent:FindFirstChild("TextLabel") :: TextLabel

local player = Players.LocalPlayer

--|| Types
type MobileButtonLayout = PlayerDataTemplate.MobileButtonLayout

type EditableControl = {
	id: string,
	frame: Frame,
}

type OriginalLayout = {
	position: UDim2,
	size: UDim2,
	transparency: number,
}

--|| Variables
local _roundConn: any = nil
local _touchDeviceConn: any = nil
local _isBound: boolean = false
local _touchGuiWatcherBound: boolean = false

local _connections: { RBXScriptConnection } = {}
local _editorConnections: { RBXScriptConnection } = {}
local _touchGuiConnections: { RBXScriptConnection } = {}
local _movementCleanup: (() -> ())? = nil
local _cameraCleanup: (() -> ())? = nil
local _promptCleanup: (() -> ())? = nil

local _editorOpen: boolean = false
local _selectedId: string? = nil
local _selectedFrame: Frame? = nil
local _originalLayout: { [string]: OriginalLayout } = {}
local _pendingLayout: { [string]: MobileButtonLayout } = {}
local _toggleOriginalColors: { [GuiObject]: Color3 } = {}

--|| Constants
local JOYSTICK_DEAD_ZONE = 0.1
local TRACKABLE_INPUT_TYPES = { Enum.UserInputType.Touch, Enum.UserInputType.MouseButton1 }
local TOGGLE_ON_COLOR = Color3.fromRGB(36, 197, 255)
local CAMERA_JOYSTICK_ID = "Camera Joystick"
-- The Size slider's knob range maps to this scale multiplier range (1.0 = the control's authored size).
local SIZE_SCALE_MIN = 0.5
local SIZE_SCALE_MAX = 1.5
local LOBBY_VISIBLE_IDS: { [string]: boolean } = { ["Movement Joystick"] = true, ["Jump"] = true }

local EDITABLE_CONTROLS: { EditableControl } = {
	{ id = "Movement Joystick", frame = movementJoystick },
	{ id = CAMERA_JOYSTICK_ID, frame = cameraJoystick },
	{ id = "Sprint", frame = sprintButton },
	{ id = "Prompt", frame = promptButton },
	{ id = "Pickup", frame = pickupButton },
	{ id = "Throw", frame = throwButton },
	{ id = "Switch", frame = switchButton },
	{ id = "Drop", frame = dropButton },
	{ id = "Pop", frame = popButton },
	{ id = "Use", frame = useButton },
	{ id = "FreeLook", frame = freeLookButton },
	{ id = "Jump", frame = jumpButton },
}

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Gui:SetAttribute("Ignored", true)

	PlayerControls.SelectTouchModule = function()
		return nil, true
	end

	editorFrame.Visible = false
	activeHighlight.Visible = false
	backgroundImage.Visible = false
	Local.SetSelectButtonsVisible(false)

	_touchDeviceConn = GuiController.OnTouchDeviceChanged:Connect(Local.SetMobileControlsEnabled)
	Local.SetMobileControlsEnabled(GuiController.IsTouchDevice)
	_roundConn = RoundController.OnPlayingChanged:Connect(Local.RefreshLobbyVisibility)

	Local.CacheOriginalLayout()
	Local.BindEditorSelection()
	Local.BindEditorDrag()
	Local.BindTransparencySlider()
	Local.BindSizeSlider()
	Local.BindToggle(lockRow:FindFirstChild("Toggle") :: Frame, Local.ToggleLock)
	Local.BindToggle(enabledRow:FindFirstChild("Toggle") :: Frame, Local.ToggleEnabled)

	local resetAllButton = buttonsRow:FindFirstChild("Reset") :: GuiButton
	local exitButton = buttonsRow:FindFirstChild("Exit") :: GuiButton
	local saveButton = buttonsRow:FindFirstChild("Save") :: GuiButton

	table.insert(_editorConnections, resetAllButton.Activated:Connect(Local.ResetAllLayout))
	table.insert(_editorConnections, saveButton.Activated:Connect(Local.SaveLayout))
	table.insert(_editorConnections, exitButton.Activated:Connect(function()
		Local.SaveLayout()
		Shared.CloseEditor()
		GuiController.SwitchActiveGui("Settings")
	end))
end

function Shared.Start()
	task.spawn(function()
		local data = DataController.GetData()
		for _, entry in EDITABLE_CONTROLS do
			local layout = Local.CloneLayout(entry.id, data.mobileLayout[entry.id]) or Local.DefaultLayout(entry.id)
			_pendingLayout[entry.id] = layout
			Local.ApplyLayout(entry.id, entry.frame, layout)
			Local.ApplyGameplayVisibility(entry.id, entry.frame, layout)
		end
	end)
end

-- [[ Private Functions ]] --
function Local.GetLocalHumanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

function Local.SetupJoystick(container: Frame, label: string, onMove: (Vector2) -> (), onRelease: () -> ()): () -> ()
	local clamp = container:FindFirstChild("Clamp") :: Frame
	local knob = clamp:FindFirstChild("Button") :: ImageButton
	local knobHome = knob.Position

	container.Active = true

	local trackedInput: InputObject? = nil

	local function updateFromPosition(inputPos: Vector3)
		local center = clamp.AbsolutePosition + clamp.AbsoluteSize / 2
		local delta = Vector2.new(inputPos.X - center.X, inputPos.Y - center.Y)
		local maxRadius = clamp.AbsoluteSize.X / 2
		if maxRadius <= 0 then return end

		local magnitude = delta.Magnitude
		local clamped = if magnitude > maxRadius then delta.Unit * maxRadius else delta

		knob.Position = UDim2.new(knobHome.X.Scale, clamped.X, knobHome.Y.Scale, clamped.Y)

		local normalized = magnitude / maxRadius
		if normalized < JOYSTICK_DEAD_ZONE then
			onMove(Vector2.zero)
		else
			local scaled = math.min(1, (normalized - JOYSTICK_DEAD_ZONE) / (1 - JOYSTICK_DEAD_ZONE))
			onMove(clamped.Unit * scaled)
		end
	end

	local function beginTracking(input: InputObject)
		if trackedInput or input.UserInputState ~= Enum.UserInputState.Begin
			or not table.find(TRACKABLE_INPUT_TYPES, input.UserInputType) then
			return
		end
		trackedInput = input
		warn(`[MobileControls] {label} drag started`)
		updateFromPosition(input.Position)
	end

	local function release()
		trackedInput = nil
		knob.Position = knobHome
		warn(`[MobileControls] {label} drag stopped`)
		onRelease()
	end

	local connections: { RBXScriptConnection } = {}

	table.insert(connections, container.InputBegan:Connect(beginTracking))
	table.insert(connections, knob.InputBegan:Connect(beginTracking))

	table.insert(connections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		updateFromPosition(input.Position)
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		release()
	end))

	return function()
		for _, conn in connections do
			conn:Disconnect()
		end
		if trackedInput then
			release()
		end
	end
end

function Local.BindPress(id: string, buttonFrame: Frame?, callback: () -> ())
	local clamp = buttonFrame and buttonFrame:FindFirstChild("Button") :: GuiButton?
	if not clamp then return end
	table.insert(_connections, clamp.Activated:Connect(function()
		warn(`[MobileControls] {id} pressed`)
		callback()
	end))
end

function Local.BindHold(id: string, buttonFrame: Frame?, onBegin: () -> (), onEnd: () -> ())
	local clamp = buttonFrame and buttonFrame:FindFirstChild("Button") :: GuiButton?
	if not clamp then return end

	local function handleBegin()
		warn(`[MobileControls] {id} hold begin`)
		onBegin()
	end

	local function handleEnd()
		warn(`[MobileControls] {id} hold end`)
		onEnd()
	end

	table.insert(_connections, clamp.MouseButton1Down:Connect(handleBegin))
	table.insert(_connections, clamp.MouseButton1Up:Connect(handleEnd))
	table.insert(_connections, clamp.MouseLeave:Connect(handleEnd))
end

function Local.BindControls()
	if _isBound then return end
	_isBound = true

	_movementCleanup = Local.SetupJoystick(movementJoystick, "Movement Joystick", function(vector: Vector2)
		local humanoid = Local.GetLocalHumanoid()
		if humanoid then
			humanoid:Move(Vector3.new(vector.X, 0, vector.Y), true)
		end
	end, function()
		local humanoid = Local.GetLocalHumanoid()
		if humanoid then
			humanoid:Move(Vector3.zero, true)
		end
	end)

	_cameraCleanup = Local.SetupJoystick(cameraJoystick, "Camera Joystick", function(vector: Vector2)
		CameraController.SetTouchLookDelta(vector)
	end, function()
		CameraController.SetTouchLookDelta(Vector2.zero)
	end)

	local promptClamp = promptButton and promptButton:FindFirstChild("Button") :: GuiButton?
	if promptClamp then
		_promptCleanup = ProximityPrompt.BindGlobalExternalButton(promptClamp)
		table.insert(_connections, promptClamp.Activated:Connect(function()
			warn("[MobileControls] Prompt pressed")
		end))
	end

	Local.BindPress("Pickup", pickupButton, function()
		InputController.FireAction("Item_Interact", Enum.UserInputState.Begin)
	end)

	Local.BindPress("Throw", throwButton, function()
		InputController.FireAction("Item_Throw", Enum.UserInputState.Begin)
	end)

	Local.BindPress("Drop", dropButton, function()
		InputController.FireAction("Item_Drop", Enum.UserInputState.Begin)
	end)

	Local.BindPress("Pop", popButton, function()
		InputController.FireAction("Item_Pop", Enum.UserInputState.Begin)
	end)

	Local.BindPress("Use", useButton, function()
		InputController.FireAction("Item_Use", Enum.UserInputState.Begin)
	end)

	Local.BindPress("Switch", switchButton, function()
		Hotbar.ToggleSlot()
	end)

	Local.BindPress("Jump", jumpButton, function()
		local humanoid = Local.GetLocalHumanoid()
		if humanoid then
			humanoid.Jump = true
		end
	end)

	Local.BindHold("Sprint", sprintButton, function()
		InputController.FireAction("Sprint", Enum.UserInputState.Begin)
	end, function()
		InputController.FireAction("Sprint", Enum.UserInputState.End)
	end)

	Local.BindHold("FreeLook", freeLookButton, function()
		InputController.FireAction("Camera_FreeLook", Enum.UserInputState.Begin)
	end, function()
		InputController.FireAction("Camera_FreeLook", Enum.UserInputState.End)
	end)
end

function Local.UnbindControls()
	if not _isBound then return end
	_isBound = false

	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	if _movementCleanup then
		_movementCleanup()
		_movementCleanup = nil
	end

	if _cameraCleanup then
		_cameraCleanup()
		_cameraCleanup = nil
	end

	if _promptCleanup then
		_promptCleanup()
		_promptCleanup = nil
	end
end

-- [[ Editor: layout data ]] --
-- Enabled only has real meaning for the Camera Joystick — every other control is locked
-- always-on ("[LOCKED]" in the editor, ToggleEnabled is a no-op for them). It's opt-in, off by default.
function Local.DefaultEnabled(id: string): boolean
	return id ~= CAMERA_JOYSTICK_ID
end

function Local.DefaultLayout(id: string): MobileButtonLayout
	local original = _originalLayout[id]
	return {
		scale = { 1, 1 },
		pos = { 0, 0 },
		transparency = original and original.transparency or 0.3,
		locked = false,
		enabled = Local.DefaultEnabled(id),
	}
end

function Local.CloneLayout(id: string, layout: MobileButtonLayout?): MobileButtonLayout?
	if not layout then return nil end
	return {
		scale = { layout.scale[1], layout.scale[2] },
		pos = { layout.pos[1], layout.pos[2] },
		transparency = layout.transparency,
		-- Same normalization as the save path (UpdateData.luau) — saved data from before this field
		-- existed has it as nil, which must fall back to the same per-control default as a fresh layout.
		locked = layout.locked == true,
		enabled = if layout.enabled == nil then Local.DefaultEnabled(id) else layout.enabled,
	}
end

function Local.GetPendingLayout(id: string): MobileButtonLayout
	if not _pendingLayout[id] then
		_pendingLayout[id] = Local.DefaultLayout(id)
	end
	return _pendingLayout[id]
end

function Local.CacheOriginalLayout()
	for _, entry in EDITABLE_CONTROLS do
		_originalLayout[entry.id] = {
			position = entry.frame.Position,
			size = entry.frame.Size,
			transparency = entry.frame.BackgroundTransparency,
		}
	end
end

function Local.ApplyLayout(id: string, frame: Frame, layout: MobileButtonLayout)
	local original = _originalLayout[id]
	if not original then return end

	frame.Position = UDim2.new(
		original.position.X.Scale + layout.pos[1], original.position.X.Offset,
		original.position.Y.Scale + layout.pos[2], original.position.Y.Offset
	)
	frame.Size = UDim2.new(
		original.size.X.Scale * layout.scale[1], original.size.X.Offset,
		original.size.Y.Scale * layout.scale[2], original.size.Y.Offset
	)
	frame.BackgroundTransparency = layout.transparency
end

function Local.ApplyGameplayVisibility(id: string, frame: Frame, layout: MobileButtonLayout)
	local visible = layout.enabled
	if visible and not RoundController.IsPlaying() then
		visible = LOBBY_VISIBLE_IDS[id] == true
	end
	frame.Visible = visible
end

function Local.RefreshLobbyVisibility()
	if _editorOpen then return end
	for _, entry in EDITABLE_CONTROLS do
		Local.ApplyGameplayVisibility(entry.id, entry.frame, Local.GetPendingLayout(entry.id))
	end
end

-- [[ Editor: selection ]] --
function Local.SelectControl(id: string, frame: Frame)
	_selectedId = id
	_selectedFrame = frame

	activeHighlight.Parent = frame
	activeHighlight.Visible = true

	selectedLabel.Text = `Selected: {id}`

	Local.RefreshSelectedDisplay()
end

function Local.RefreshSelectedDisplay()
	if not _selectedId then return end
	local layout = Local.GetPendingLayout(_selectedId)

	local transparencyLabel = transparencyRow:FindFirstChild("Label") :: TextLabel
	local transparencyKnob = transparencyRow.Slider.Bar:FindFirstChild("Button") :: GuiObject
	local transparencyKnobY = transparencyKnob.Position.Y
	transparencyKnob.Position = UDim2.new(layout.transparency, 0, transparencyKnobY.Scale, transparencyKnobY.Offset)
	transparencyLabel.Text = `Transparency: {math.floor(layout.transparency * 100 + 0.5)}%`

	local sizeScale = layout.scale[1]
	local sizePercent = math.clamp((sizeScale - SIZE_SCALE_MIN) / (SIZE_SCALE_MAX - SIZE_SCALE_MIN), 0, 1)
	local sizeLabel = sizeRow:FindFirstChild("Label") :: TextLabel
	local sizeKnob = sizeRow.Slider.Bar:FindFirstChild("Button") :: GuiObject
	local sizeKnobY = sizeKnob.Position.Y
	sizeKnob.Position = UDim2.new(sizePercent, 0, sizeKnobY.Scale, sizeKnobY.Offset)
	sizeLabel.Text = `Size: {math.floor(sizeScale * 100 + 0.5)}%`

	Local.SetToggleState(lockRow:FindFirstChild("Toggle") :: Frame, layout.locked)

	local enabledLabel = enabledRow:FindFirstChild("Label") :: TextLabel
	local enabledToggle = enabledRow:FindFirstChild("Toggle") :: Frame

	if _selectedId == CAMERA_JOYSTICK_ID then
		enabledLabel.Text = "Enabled"
		enabledToggle.Visible = true
		Local.SetToggleState(enabledToggle, layout.enabled)
	else
		enabledLabel.Text = "[LOCKED]"
		enabledToggle.Visible = false
	end
end

function Local.SetToggleState(toggleFrame: Frame, state: boolean)
	local knob = toggleFrame:FindFirstChild("Button") :: GuiObject
	if not knob then return end

	if not _toggleOriginalColors[knob] then
		_toggleOriginalColors[knob] = knob.BackgroundColor3
	end

	knob.BackgroundColor3 = if state then TOGGLE_ON_COLOR else _toggleOriginalColors[knob]
end

function Local.BindToggle(toggleFrame: Frame?, callback: () -> ())
	local knob = toggleFrame and toggleFrame:FindFirstChild("Button") :: GuiButton?
	if not knob then return end
	knob.Active = true
	table.insert(_editorConnections, knob.Activated:Connect(callback))
end

function Local.ToggleLock()
	if not _selectedId then return end
	local layout = Local.GetPendingLayout(_selectedId)
	layout.locked = not layout.locked
	Local.SetToggleState(lockRow:FindFirstChild("Toggle") :: Frame, layout.locked)
end

function Local.ToggleEnabled()
	if not _selectedId or _selectedId ~= CAMERA_JOYSTICK_ID then return end
	local layout = Local.GetPendingLayout(_selectedId)
	layout.enabled = not layout.enabled
	Local.SetToggleState(enabledRow:FindFirstChild("Toggle") :: Frame, layout.enabled)
	-- Stays visible regardless, so it's still selectable/re-toggleable — real hiding is applied
	-- once the editor closes, in Shared.CloseEditor.
end

function Local.ResetAllLayout()
	for _, entry in EDITABLE_CONTROLS do
		_pendingLayout[entry.id] = Local.DefaultLayout(entry.id)
		Local.ApplyLayout(entry.id, entry.frame, _pendingLayout[entry.id])
	end

	if _selectedId then
		Local.RefreshSelectedDisplay()
	end
end

function Local.SaveLayout()
	for _, entry in EDITABLE_CONTROLS do
		DataController.RequestUpdate({
			type = "UpdateMobileLayout",
			data = { buttonId = entry.id, layout = Local.GetPendingLayout(entry.id) },
		})
	end
end

-- [[ Editor: input ]] --
function Local.SetSelectButtonsVisible(visible: boolean)
	for _, entry in EDITABLE_CONTROLS do
		local selectButton = entry.frame:FindFirstChild("Select", true) :: GuiButton?
		if selectButton then
			selectButton.Visible = visible
		end
	end
end

function Local.BindEditorSelection()
	for _, entry in EDITABLE_CONTROLS do
		local frame = entry.frame
		local selectButton = frame:FindFirstChild("Select") :: GuiButton?
		if not selectButton then continue end

		local trackedInput: InputObject? = nil
		local dragStartInputPos: Vector2? = nil
		local dragStartFramePos: UDim2? = nil

		table.insert(_editorConnections, selectButton.InputBegan:Connect(function(input: InputObject)
			if not _editorOpen or trackedInput or input.UserInputState ~= Enum.UserInputState.Begin
				or not table.find(TRACKABLE_INPUT_TYPES, input.UserInputType) then
				return
			end

			local layout = Local.GetPendingLayout(entry.id)
			Local.SelectControl(entry.id, frame)
			warn(`[MobileControls] {entry.id} selected`)
			if layout.locked then return end

			trackedInput = input
			warn(`[MobileControls] {entry.id} position drag started`)
			dragStartInputPos = Vector2.new(input.Position.X, input.Position.Y)
			dragStartFramePos = frame.Position
		end))

		table.insert(_editorConnections, UserInputService.InputChanged:Connect(function(input: InputObject)
			if input ~= trackedInput or not dragStartInputPos or not dragStartFramePos then return end

			local parentSize = Workspace.CurrentCamera.ViewportSize
			if parentSize.X <= 0 or parentSize.Y <= 0 then return end

			local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStartInputPos
			frame.Position = UDim2.new(
				dragStartFramePos.X.Scale + delta.X / parentSize.X, dragStartFramePos.X.Offset,
				dragStartFramePos.Y.Scale + delta.Y / parentSize.Y, dragStartFramePos.Y.Offset
			)
		end))

		table.insert(_editorConnections, UserInputService.InputEnded:Connect(function(input: InputObject)
			if input ~= trackedInput then return end
			trackedInput = nil
			dragStartInputPos = nil
			dragStartFramePos = nil
			warn(`[MobileControls] {entry.id} position drag stopped`)

			local original = _originalLayout[entry.id]
			if not original then return end

			local layout = Local.GetPendingLayout(entry.id)
			layout.pos = {
				frame.Position.X.Scale - original.position.X.Scale,
				frame.Position.Y.Scale - original.position.Y.Scale,
			}
		end))
	end
end

-- Drags the whole floating Editor panel by its handle, independent of control selection/repositioning.
function Local.BindEditorDrag()
	editorDrag.Active = true

	local trackedInput: InputObject? = nil
	local dragStartInputPos: Vector2? = nil
	local dragStartFramePos: UDim2? = nil

	table.insert(_editorConnections, editorDrag.InputBegan:Connect(function(input: InputObject)
		if trackedInput or input.UserInputState ~= Enum.UserInputState.Begin
			or not table.find(TRACKABLE_INPUT_TYPES, input.UserInputType) then
			return
		end
		trackedInput = input
		warn("[MobileControls] Editor panel drag started")
		dragStartInputPos = Vector2.new(input.Position.X, input.Position.Y)
		dragStartFramePos = editorFrame.Position
	end))

	table.insert(_editorConnections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if input ~= trackedInput or not dragStartInputPos or not dragStartFramePos then return end

		local parentSize = Workspace.CurrentCamera.ViewportSize
		if parentSize.X <= 0 or parentSize.Y <= 0 then return end

		local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStartInputPos
		editorFrame.Position = UDim2.new(
			dragStartFramePos.X.Scale + delta.X / parentSize.X, dragStartFramePos.X.Offset,
			dragStartFramePos.Y.Scale + delta.Y / parentSize.Y, dragStartFramePos.Y.Offset
		)
	end))

	table.insert(_editorConnections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		trackedInput = nil
		dragStartInputPos = nil
		dragStartFramePos = nil
		warn("[MobileControls] Editor panel drag stopped")
	end))
end

-- Adjusts the *selected* control's transparency live; only persisted into its pending layout on release.
function Local.BindTransparencySlider()
	local bar = transparencyRow.Slider.Bar :: Frame
	local knob = bar:FindFirstChild("Button") :: ImageButton
	local knobY = knob.Position.Y

	knob.Active = true

	local trackedInput: InputObject? = nil

	local function percentFromInput(inputPos: Vector3): number
		local barWidth = bar.AbsoluteSize.X
		if barWidth <= 0 then return 0 end
		return math.clamp((inputPos.X - bar.AbsolutePosition.X) / barWidth, 0, 1)
	end

	local function applyPercent(percent: number)
		knob.Position = UDim2.new(percent, 0, knobY.Scale, knobY.Offset)

		local transparencyLabel = transparencyRow:FindFirstChild("Label") :: TextLabel
		transparencyLabel.Text = `Transparency: {math.floor(percent * 100 + 0.5)}%`

		if _selectedFrame then
			_selectedFrame.BackgroundTransparency = percent
		end
	end

	table.insert(_editorConnections, knob.InputBegan:Connect(function(input: InputObject)
		if not _editorOpen or not _selectedId or trackedInput or input.UserInputState ~= Enum.UserInputState.Begin
			or not table.find(TRACKABLE_INPUT_TYPES, input.UserInputType) then
			return
		end
		trackedInput = input
		warn("[MobileControls] Transparency slider drag started")
		applyPercent(percentFromInput(input.Position))
	end))

	table.insert(_editorConnections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		applyPercent(percentFromInput(input.Position))
	end))

	table.insert(_editorConnections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		trackedInput = nil
		warn("[MobileControls] Transparency slider drag stopped")

		if _selectedId then
			Local.GetPendingLayout(_selectedId).transparency = percentFromInput(input.Position)
		end
	end))
end

-- Adjusts the *selected* control's size live (uniformly X/Y); only persisted on release. Knob
-- percent maps onto [SIZE_SCALE_MIN, SIZE_SCALE_MAX], displayed as the resulting scale percentage
-- (e.g. knob centered -> 100%), not the raw knob position.
function Local.BindSizeSlider()
	local bar = sizeRow.Slider.Bar :: Frame
	local knob = bar:FindFirstChild("Button") :: ImageButton
	local knobY = knob.Position.Y

	knob.Active = true

	local trackedInput: InputObject? = nil

	local function percentFromInput(inputPos: Vector3): number
		local barWidth = bar.AbsoluteSize.X
		if barWidth <= 0 then return 0 end
		return math.clamp((inputPos.X - bar.AbsolutePosition.X) / barWidth, 0, 1)
	end

	local function applyPercent(percent: number)
		knob.Position = UDim2.new(percent, 0, knobY.Scale, knobY.Offset)

		local scale = SIZE_SCALE_MIN + percent * (SIZE_SCALE_MAX - SIZE_SCALE_MIN)

		local sizeLabel = sizeRow:FindFirstChild("Label") :: TextLabel
		sizeLabel.Text = `Size: {math.floor(scale * 100 + 0.5)}%`

		local original = _selectedId and _originalLayout[_selectedId]
		if _selectedFrame and original then
			_selectedFrame.Size = UDim2.new(
				original.size.X.Scale * scale, original.size.X.Offset,
				original.size.Y.Scale * scale, original.size.Y.Offset
			)
		end
	end

	table.insert(_editorConnections, knob.InputBegan:Connect(function(input: InputObject)
		if not _editorOpen or not _selectedId or trackedInput or input.UserInputState ~= Enum.UserInputState.Begin
			or not table.find(TRACKABLE_INPUT_TYPES, input.UserInputType) then
			return
		end
		trackedInput = input
		warn("[MobileControls] Size slider drag started")
		applyPercent(percentFromInput(input.Position))
	end))

	table.insert(_editorConnections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		applyPercent(percentFromInput(input.Position))
	end))

	table.insert(_editorConnections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input ~= trackedInput then return end
		trackedInput = nil
		warn("[MobileControls] Size slider drag stopped")

		if _selectedId then
			local percent = percentFromInput(input.Position)
			local scale = SIZE_SCALE_MIN + percent * (SIZE_SCALE_MAX - SIZE_SCALE_MIN)
			Local.GetPendingLayout(_selectedId).scale = { scale, scale }
		end
	end))
end

-- ControlModule's own TouchGui visibility check never looks at movement mode, so it can end up
-- shown regardless — it's suppressed directly here instead, along with force-disabling whatever
-- movement controller it currently has active (DynamicThumbstick, etc).
function Local.SuppressTouchGui()
	if _touchGuiWatcherBound then return end
	_touchGuiWatcherBound = true

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	local function suppress(gui: Instance)
		if not gui:IsA("ScreenGui") or gui.Name ~= "TouchGui" then return end
		gui.Enabled = false
		table.insert(_touchGuiConnections, gui:GetPropertyChangedSignal("Enabled"):Connect(function()
			if gui.Enabled then
				gui.Enabled = false
			end
		end))
	end

	local existing = playerGui:FindFirstChild("TouchGui")
	if existing then
		suppress(existing)
	end

	table.insert(_touchGuiConnections, playerGui.ChildAdded:Connect(suppress))
end

function Local.DisableDefaultTouchController()
	local activeController = PlayerControls:GetActiveController()
	if activeController then
		activeController:Enable(false)
	end
end

function Local.SetMobileControlsEnabled(enabled: boolean)
	Gui.Enabled = enabled

	if enabled then
		Local.SuppressTouchGui()
		Local.DisableDefaultTouchController()
		Local.BindControls()
	else
		Local.UnbindControls()
	end
end

-- [[ Public Functions ]] --
-- Editing is allowed regardless of device (PC included) — only actually using the controls at
-- spawn is gated on GuiController.IsTouchDevice, so the Gui is force-enabled here independent of that.
function Shared.OpenEditor()
	if _editorOpen then return end
	_editorOpen = true

	Gui.Enabled = true
	backgroundImage.Visible = true
	Local.SetSelectButtonsVisible(true)
	Local.UnbindControls()
	editorFrame.Visible = true

	task.spawn(function()
		local data = DataController.GetData()
		for _, entry in EDITABLE_CONTROLS do
			_pendingLayout[entry.id] = Local.CloneLayout(entry.id, data.mobileLayout[entry.id]) or Local.DefaultLayout(entry.id)
			Local.ApplyLayout(entry.id, entry.frame, _pendingLayout[entry.id])
			entry.frame.Visible = true
		end
	end)
end

function Shared.CloseEditor()
	if not _editorOpen then return end
	_editorOpen = false

	editorFrame.Visible = false
	backgroundImage.Visible = false
	Local.SetSelectButtonsVisible(false)
	activeHighlight.Visible = false
	activeHighlight.Parent = Gui
	_selectedId = nil
	_selectedFrame = nil

	for _, entry in EDITABLE_CONTROLS do
		Local.ApplyGameplayVisibility(entry.id, entry.frame, Local.GetPendingLayout(entry.id))
	end

	Local.SetMobileControlsEnabled(GuiController.IsTouchDevice)
end

function Shared.Destroy()
	if _roundConn then
		_roundConn:Disconnect()
		_roundConn = nil
	end

	if _touchDeviceConn then
		_touchDeviceConn:Disconnect()
		_touchDeviceConn = nil
	end

	for _, conn in _editorConnections do
		conn:Disconnect()
	end
	table.clear(_editorConnections)

	for _, conn in _touchGuiConnections do
		conn:Disconnect()
	end
	table.clear(_touchGuiConnections)
	_touchGuiWatcherBound = false

	-- Removing the own-key override falls back through __index to ControlModule's real method.
	PlayerControls.SelectTouchModule = nil

	Local.SetMobileControlsEnabled(false)
end

return Shared
