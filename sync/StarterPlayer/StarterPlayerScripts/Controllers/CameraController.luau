--|| Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

--|| References
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)
local UtilsLibrary = require(ReplicatedStorage.Modules.Utils.UtilsLibrary)

local InputController = require(ReplicatedStorage.Modules.Shared.InputController)
local ActionPromptController = require(script.Parent.Gui.ActionPrompt)

local GuiController = require(script.Parent.GuiController)
local CursorGui = GuiController.Guis.Cursor

local player = Players.LocalPlayer

--|| Variables
local _connections: { RBXScriptConnection } = {}
local _freeLookHandle: any = nil

local _isEnabled: boolean = false
local _isFreeLook: boolean = false
local _isSnappingBack: boolean = false

local _pitch: number = 0
local _yaw: number = 0
local _snapTargetYaw: number = 0

local _lastInputWasGamepad: boolean = false
local _suppressed: boolean = false

--|| Constants
local FREE_LOOK_ACTION = "Camera_FreeLook"
local FREE_LOOK_KEYS = { Enum.KeyCode.LeftAlt, Enum.KeyCode.ButtonL2 }
local ROUND_STATE_ATTR = "RoundState"

local CAMERA_OFFSET = Vector3.new(2.5, 1.5, 7.5)
local SENSITIVITY = 0.15
local GAMEPAD_SENSITIVITY = 3.5
local PITCH_LIMIT = 75
local GAMEPAD_DEADZONE = 0.15

local ALIGN_RESPONSIVENESS = 30
local SNAP_BACK_SPEED = 10

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.RespectCanCollide = true
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAYCAST_PARAMS.IgnoreWater = true

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	RunService:BindToRenderStep("OTSCameraUpdate", Enum.RenderPriority.Camera.Value, Local.OnRenderStepped)

	UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		_lastInputWasGamepad = UserInputService.PreferredInput.Name:lower():find("gamepad") ~= nil

		local otherKey = _lastInputWasGamepad and FREE_LOOK_KEYS[1] or FREE_LOOK_KEYS[2]
		local key = _lastInputWasGamepad and FREE_LOOK_KEYS[2] or FREE_LOOK_KEYS[1]

		local text = _isFreeLook and "Release Free Look" or "Free Look"

		ActionPromptController.ShowPrompt(key, text)
		ActionPromptController.HidePrompt(otherKey)
	end)

	UserInputService.GamepadConnected:Connect(function(gamepadNum: Enum.UserInputType)
		_lastInputWasGamepad = true

		local otherKey = _lastInputWasGamepad and FREE_LOOK_KEYS[1] or FREE_LOOK_KEYS[2]
		local key = _lastInputWasGamepad and FREE_LOOK_KEYS[2] or FREE_LOOK_KEYS[1]

		local text = _isFreeLook and "Release Free Look" or "Free Look"

		ActionPromptController.ShowPrompt(key, text)
		ActionPromptController.HidePrompt(otherKey)
	end)

	UserInputService.GamepadDisconnected:Connect(function(gamepadNum: Enum.UserInputType)
		_lastInputWasGamepad = false

		local otherKey = _lastInputWasGamepad and FREE_LOOK_KEYS[1] or FREE_LOOK_KEYS[2]
		local key = _lastInputWasGamepad and FREE_LOOK_KEYS[2] or FREE_LOOK_KEYS[1]

		local text = _isFreeLook and "Release Free Look" or "Free Look"

		ActionPromptController.ShowPrompt(key, text)
		ActionPromptController.HidePrompt(otherKey)
	end)

	Observers.observeCharacter(function(_player: Player, _character: Model): (() -> ())?
		if _player ~= player then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return function() end
		end

		if workspace.CurrentCamera.CameraSubject ~= humanoid then
			workspace.CurrentCamera.CameraSubject = humanoid
		end

		return function() end
	end)
end

function Shared.Start()
	Local.OnRoundStateChanged()
	table.insert(_connections, Workspace:GetAttributeChangedSignal(ROUND_STATE_ATTR):Connect(Local.OnRoundStateChanged))
end

-- [[ Private Functions ]] --
function Local.OnRoundStateChanged()
	local att = Workspace:GetAttribute(ROUND_STATE_ATTR)
	if not _suppressed and (att == "Starting" or att == "InProgress") then
		Shared.Enable()
	else
		Shared.Disable()
	end
end

function Local.GetOrSetupAlign(hrp: BasePart): AlignOrientation
	local align = hrp:FindFirstChild("OTS_Align") :: AlignOrientation
	if align then
		return align
	end

	local att = Instance.new("Attachment")
	att.Name = "OTS_Attachment"
	att.Parent = hrp

	align = Instance.new("AlignOrientation")
	align.Name = "OTS_Align"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.MaxTorque = 100000
	align.MaxAngularVelocity = math.huge
	align.Responsiveness = ALIGN_RESPONSIVENESS
	align.Parent = hrp

	return align
end

function Local.GetThumbstickDelta(): Vector2
	local gamepadState = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	for _, inputObject in gamepadState do
		if inputObject.KeyCode == Enum.KeyCode.Thumbstick2 then
			local pos = inputObject.Position
			local x = math.abs(pos.X) > GAMEPAD_DEADZONE and pos.X or 0
			local y = math.abs(pos.Y) > GAMEPAD_DEADZONE and pos.Y or 0
			return Vector2.new(x, y)
		end
	end
	return Vector2.zero
end

function Local.GetInputDelta(dt: number): Vector2
	local thumbstick = Local.GetThumbstickDelta()
	local mouseDelta = UserInputService:GetMouseDelta()

	if thumbstick.Magnitude > 0 then
		_lastInputWasGamepad = true
		return thumbstick * GAMEPAD_SENSITIVITY * dt * 60
	end

	if mouseDelta.Magnitude > 0 then
		_lastInputWasGamepad = false
	end

	return mouseDelta * SENSITIVITY
end

function Local.OnFreeLook(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
	local key = _lastInputWasGamepad and FREE_LOOK_KEYS[2] or FREE_LOOK_KEYS[1]

	if state == Enum.UserInputState.Begin then
		_isFreeLook = true
		_isSnappingBack = false

		ActionPromptController.ChangeActionText(key, "Release Free Look")
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		_isFreeLook = false
		_isSnappingBack = true

		ActionPromptController.ChangeActionText(key, "Free Look")

		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart
		if hrp then
			local _, targetYawRad, _ = hrp.CFrame:ToOrientation()
			_snapTargetYaw = math.deg(targetYawRad)
		else
			_snapTargetYaw = _yaw
		end
	end

	return Enum.ContextActionResult.Pass
end

function Local.OnRenderStepped(dt: number)
	if not _isEnabled then
		return
	end

	local camera = Workspace.CurrentCamera
	local character = player.Character
	if not camera or not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if not hrp or not humanoid or humanoid.Health <= 0 then
		return
	end

	if not _lastInputWasGamepad then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end

	local delta = Local.GetInputDelta(dt)

	if _isSnappingBack then
		local diff = (_snapTargetYaw - _yaw) % 360
		if diff > 180 then
			diff -= 360
		end

		local lerpAlpha = 1 - math.exp(-SNAP_BACK_SPEED * dt)
		_yaw += diff * lerpAlpha

		if math.abs(diff) < 0.5 then
			_yaw = _snapTargetYaw
			_isSnappingBack = false
		end
	else
		_yaw -= delta.X
	end

	_pitch -= delta.Y
	_pitch = math.clamp(_pitch, -PITCH_LIMIT, PITCH_LIMIT)

	local focusPos = hrp.Position + Vector3.new(0, 1.5, 0)
	local camRotation = CFrame.Angles(0, math.rad(_yaw), 0) * CFrame.Angles(math.rad(_pitch), 0, 0)
	local targetPos = focusPos + (camRotation * CAMERA_OFFSET)

	RAYCAST_PARAMS.FilterDescendantsInstances = UtilsLibrary.tableUtils.Extend(
		CollectionService:GetTagged("Player"),
		CollectionService:GetTagged("THROWN_ITEM"),
		CollectionService:GetTagged("NPCBarricade")
	)
	local direction = targetPos - focusPos
	local result = Workspace:Raycast(focusPos, direction, RAYCAST_PARAMS)

	local finalPos = targetPos
	if result then
		finalPos = result.Position - (direction.Unit * 0.5)
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(finalPos) * camRotation

	local align = Local.GetOrSetupAlign(hrp)

	if _isFreeLook then
		humanoid.AutoRotate = true
		align.Enabled = false
	else
		humanoid.AutoRotate = false
		align.Enabled = true

		local lookVector = camRotation.LookVector
		local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)

		if flatLook.Magnitude > 0.1 then
			align.CFrame = CFrame.lookAt(Vector3.zero, flatLook.Unit)
		end
	end
end

-- [[ Public Functions ]] --
function Shared.Enable()
	if _isEnabled then
		return
	end
	_isEnabled = true

	if not _lastInputWasGamepad then
		UserInputService.MouseIconEnabled = false
		CursorGui.Enabled = true
	end

	local character = player.Character
	if character and character.PrimaryPart then
		local _, yRad, _ = character.PrimaryPart.CFrame:ToOrientation()
		_yaw = math.deg(yRad)
		_pitch = 0
	end

	_freeLookHandle = InputController.BindAction({
		name = FREE_LOOK_ACTION,
		keys = FREE_LOOK_KEYS,
		priority = Enum.ContextActionPriority.High.Value,
		callback = Local.OnFreeLook,
	})

	local key = _lastInputWasGamepad and FREE_LOOK_KEYS[2] or FREE_LOOK_KEYS[1]

	ActionPromptController.ShowPrompt(key, "Free Look")
end

function Shared.Disable()
	if not _isEnabled then
		return
	end
	_isEnabled = false

	if _freeLookHandle then
		_freeLookHandle:Unbind()
		_freeLookHandle = nil
	end

	local key = _lastInputWasGamepad and FREE_LOOK_KEYS[2] or FREE_LOOK_KEYS[1]

	ActionPromptController.HidePrompt(key)

	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end

	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	CursorGui.Enabled = false

	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildWhichIsA("Humanoid")
		if humanoid then
			humanoid.AutoRotate = true
		end

		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local align = hrp:FindFirstChild("OTS_Align")
			if align then
				align:Destroy()
			end
			local att = hrp:FindFirstChild("OTS_Attachment")
			if att then
				att:Destroy()
			end
		end
	end
end

function Shared.GetLookTarget(maxDistance: number, customParams: RaycastParams?): RaycastResult?
	if not _isEnabled then
		return nil
	end

	local camera = Workspace.CurrentCamera
	local character = player.Character
	if not camera or not character then
		return nil
	end

	RAYCAST_PARAMS.FilterDescendantsInstances = { character }

	local rayParams = customParams or RAYCAST_PARAMS

	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * maxDistance

	local result = Workspace:Raycast(origin, direction, rayParams)
	-- print(script.Name, result)

	return result
end

function Shared.IsFreeLook(): boolean
	return _isFreeLook
end

-- Lets other controllers hold free-look/mouse-lock off during a forced UI window without racing the
-- RoundState listener above — re-evaluates against the live state on release rather than blind-Enable.
function Shared.SetSuppressed(suppressed: boolean)
	if _suppressed == suppressed then
		return
	end
	_suppressed = suppressed
	Local.OnRoundStateChanged()
end

function Shared.Destroy()
	Shared.Disable()

	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	RunService:UnbindFromRenderStep("OTSCameraUpdate")
end

return Shared
