--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)
local ProximityPrompt = require(ReplicatedStorage.Modules.Shared.Classes.ProximityPrompt)

local player = Players.LocalPlayer

--|| Variables
local _activePrompts: {[Seat]: ProximityPrompt.ClassType} = {}
local _seats: {[Seat]: true} = {}
local _nearestSeat: Seat? = nil

local _renderConn: RBXScriptConnection? = nil
local _stopCharacterObserver: (() -> ())? = nil
local _isLocalPlayerSeated: boolean = false

--|| Constants
local PLAYER_SEAT_TAG = "PlayerSeat"

local MAX_SIT_DISTANCE = 5
local SIT_HOLD_DURATION = 0

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Observers.observeTag(PLAYER_SEAT_TAG, function(seat): (() -> ())?
		task.spawn(Local.SetupPrompt, seat)

		return function()
			task.spawn(Local.TeardownPrompt, seat)
		end
	end)

	_renderConn = RunService.RenderStepped:Connect(Local.OnRenderStepped)

	_stopCharacterObserver = Observers.observeLocalCharacter(function(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if not humanoid then return end

		local seatedConn = humanoid.Seated:Connect(function(active: boolean)
			_isLocalPlayerSeated = active
			if active then
				Local.SetNearestSeat(nil)
			end
		end)

		return function()
			seatedConn:Disconnect()
			_isLocalPlayerSeated = false
		end
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.SetupPrompt(seat: Instance)
	if not seat:IsA("Seat") then return end
	if _activePrompts[seat] then return end

	local prompt = ProximityPrompt.new({
		name = `Seat_{seat:GetFullName()}`,
		actionText = "Sit",
		objectText = "Seat",
		holdDuration = SIT_HOLD_DURATION,
		maxActivationDistance = MAX_SIT_DISTANCE,
		enabled = false, -- Local.OnRenderStepped is the only thing that ever enables a seat prompt
		keyboardKeyCode = Enum.KeyCode.E,
		gamepadKeyCode = Enum.KeyCode.ButtonX,
		parent = seat,
	})

	prompt.Triggered:Connect(function()
		Network:FireServer("Seat", "Sit", { seat = seat })
	end)

	_activePrompts[seat :: Seat] = prompt
	_seats[seat :: Seat] = true
end

function Local.TeardownPrompt(seat: Instance)
	local prompt = _activePrompts[seat :: Seat]
	if not prompt then return end

	_seats[seat :: Seat] = nil
	if _nearestSeat == seat then
		_nearestSeat = nil
	end

	prompt:Destroy()
	_activePrompts[seat :: Seat] = nil
end

-- Only the closest unoccupied seat in range is ever enabled, so a cluster of chairs doesn't all
-- light up at once — suppressed entirely while the local player is already seated.
function Local.OnRenderStepped()
	if _isLocalPlayerSeated then
		Local.SetNearestSeat(nil)
		return
	end

	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		Local.SetNearestSeat(nil)
		return
	end

	local nearestSeat: Seat? = nil
	local nearestDistance = MAX_SIT_DISTANCE

	for seat in _seats do
		if seat.Occupant then continue end

		local distance = (hrp.Position - seat.Position).Magnitude
		if distance <= nearestDistance then
			nearestDistance = distance
			nearestSeat = seat
		end
	end

	Local.SetNearestSeat(nearestSeat)
end

function Local.SetNearestSeat(seat: Seat?)
	if seat == _nearestSeat then return end

	if _nearestSeat then
		local prevPrompt = _activePrompts[_nearestSeat]
		if prevPrompt then prevPrompt:SetEnabled(false) end
	end

	_nearestSeat = seat

	if _nearestSeat then
		local prompt = _activePrompts[_nearestSeat]
		if prompt then prompt:SetEnabled(true) end
	end
end

-- [[ Public Functions ]] --
function Shared.Destroy()
	if _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end

	if _stopCharacterObserver then
		_stopCharacterObserver()
		_stopCharacterObserver = nil
	end

	for _, prompt in _activePrompts do
		prompt:Destroy()
	end
	table.clear(_activePrompts)
	table.clear(_seats)
	_nearestSeat = nil
end

return Shared
