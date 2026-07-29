--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

--|| Types
type MotorState = {
	motor: Motor6D,
	enabled: boolean,
}

type PartCollisionState = {
	group: string,
	canCollide: boolean,
}

type RagdollState = {
	rig: Model,
	player: Player?,
	motorStates: { MotorState },
	ballSockets: { BallSocketConstraint },
	attachments: { Attachment },
	collisionStates: { [BasePart]: PartCollisionState },
	restored: boolean,
}

--|| Variables
local _activeRagdolls: { [Model]: RagdollState } = {}
local _destroyingConnections: { [Model]: RBXScriptConnection } = {}

--|| Constants
local VELOCITY_SETTLE_THRESHOLD = .75
local VELOCITY_POLL_INTERVAL = 0.1
local SETTLE_WAIT_SECONDS = 3
local MAX_RAGDOLL_SECONDS = 8
local RAGDOLL_COLLISION_GROUP = "RagdollLimb"
local BALLSOCKET_UPPER_ANGLE = 45
local BALLSOCKET_TWIST_LOWER_ANGLE = -45
local BALLSOCKET_TWIST_UPPER_ANGLE = 45

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Signals ]] --
Shared.OnPlayerRagdolled = ModuleUtils.signal.new() :: typeof(ModuleUtils.signal.new())

Shared.OnRagdolled = ModuleUtils.signal.new() :: typeof(ModuleUtils.signal.new())

-- [[ Startup ]] --
function Shared.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		local rig = player.Character
		if rig and _activeRagdolls[rig] then
			Local.CleanupState(rig)
		end
	end)
end

function Shared.Start()

end

-- [[ Private Functions ]] --

function Local.ResolveTarget(target: Player | Model): (Model?, Player?)
	if typeof(target) == "Instance" then
		if target:IsA("Player") then
			return target.Character, target
		elseif target:IsA("Model") then
			return target, Players:GetPlayerFromCharacter(target)
		end
	end
	return nil, nil
end

function Local.CleanupState(rig: Model)
	_activeRagdolls[rig] = nil

	local conn = _destroyingConnections[rig]
	if conn then
		conn:Disconnect()
		_destroyingConnections[rig] = nil
	end
end

function Local.DisableMotors(rig: Model): { MotorState }
	local motorStates: { MotorState } = {}

	for _, joint in rig:GetDescendants() do
		if joint:IsA("Motor6D") then
			table.insert(motorStates, {
				motor = joint,
				enabled = joint.Enabled,
			})
			joint.Enabled = false
		end
	end

	return motorStates
end

function Local.EnableMotors(motorStates: { MotorState })
	for _, state in motorStates do
		if state.motor and state.motor.Parent then
			state.motor.Enabled = state.enabled
		end
	end
end

function Local.AddBallSockets(rig: Model): ({ BallSocketConstraint }, { Attachment })
	local ballSockets: { BallSocketConstraint } = {}
	local attachments: { Attachment } = {}

	for _, joint in rig:GetDescendants() do
		if joint:IsA("Motor6D") and joint.Part0 and joint.Part1 then
			local a0 = Instance.new("Attachment")
			local a1 = Instance.new("Attachment")
			a0.CFrame = joint.C0
			a1.CFrame = joint.C1
			a0.Parent = joint.Part0
			a1.Parent = joint.Part1

			local ball = Instance.new("BallSocketConstraint")
			ball.Attachment0 = a0
			ball.Attachment1 = a1
			ball.LimitsEnabled = true
			ball.UpperAngle = BALLSOCKET_UPPER_ANGLE
			ball.TwistLimitsEnabled = true
			ball.TwistLowerAngle = BALLSOCKET_TWIST_LOWER_ANGLE
			ball.TwistUpperAngle = BALLSOCKET_TWIST_UPPER_ANGLE
			ball.Parent = joint.Parent

			table.insert(ballSockets, ball)
			table.insert(attachments, a0)
			table.insert(attachments, a1)
		end
	end

	return ballSockets, attachments
end

function Local.RemoveBallSockets(ballSockets: { BallSocketConstraint }, attachments: { Attachment })
	for _, ball in ballSockets do
		if ball and ball.Parent then
			ball:Destroy()
		end
	end

	for _, att in attachments do
		if att and att.Parent then
			att:Destroy()
		end
	end
end

function Local.ApplyRagdollCollisionState(rig: Model): { [BasePart]: PartCollisionState }
	local collisionStates: { [BasePart]: PartCollisionState } = {}

	for _, part in rig:GetDescendants() do
		if part:IsA("BasePart") then
			collisionStates[part] = {
				group = part.CollisionGroup,
				canCollide = part.CanCollide,
			}

			part.CollisionGroup = RAGDOLL_COLLISION_GROUP
			part.CanCollide = true
		end
	end

	return collisionStates
end

function Local.RestoreCollisionState(collisionStates: { [BasePart]: PartCollisionState })
	for part, original in collisionStates do
		if part and part.Parent then
			part.CollisionGroup = original.group
			part.CanCollide = original.canCollide
		end
	end
end

function Local.SetServerOwnership(rig: Model)
	for _, part in rig:GetDescendants() do
		if part:IsA("BasePart") then
			local ok = pcall(function()
				part:SetNetworkOwner(nil)
			end)
			if not ok then
			end
		end
	end
end

function Local.ResetOwnership(rig: Model)
	for _, part in rig:GetDescendants() do
		if part:IsA("BasePart") then
			pcall(function()
				part:SetNetworkOwnershipAuto()
			end)
		end
	end
end

function Local.StopAnimations(rig: Model)
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end

	for _, track in animator:GetPlayingAnimationTracks() do
		track:Stop(0)
	end
end

function Local.ApplyForce(rig: Model, hitPosition: Vector3, direction: Vector3, force: number)
	local root = rig.PrimaryPart
	if not root then return end

	local closestPart: BasePart? = nil
	local closestDist = math.huge

	for _, part in rig:GetDescendants() do
		if part:IsA("BasePart") then
			local dist = (part.Position - hitPosition).Magnitude
			if dist < closestDist then
				closestDist = dist
				closestPart = part
			end
		end
	end

	if closestPart then
		closestPart:ApplyImpulseAtPosition(direction * force, hitPosition)
	end
end

function Local.WaitForSettle(rig: Model): boolean
	local root = rig.PrimaryPart
	if not root then return true end

	local elapsed = 0

	while elapsed < MAX_RAGDOLL_SECONDS do
		task.wait(VELOCITY_POLL_INTERVAL)
		elapsed += VELOCITY_POLL_INTERVAL

		if not rig or not rig.Parent then return false end

		if root.AssemblyLinearVelocity.Magnitude < VELOCITY_SETTLE_THRESHOLD then
			return true
		end
	end

	return true
end

function Local.RunRestoreTimer(rig: Model)
	task.spawn(function()
		Local.WaitForSettle(rig)

		local state = _activeRagdolls[rig]
		if not state or state.restored then return end

		task.wait(SETTLE_WAIT_SECONDS)

		state = _activeRagdolls[rig]
		if not state or state.restored then return end

		Shared.Restore(rig)
	end)
end

-- [[ Public Functions ]] --

function Shared.Ragdoll(target: Player | Model, hitPosition: Vector3, direction: Vector3, force: number)
	local rig, player = Local.ResolveTarget(target)
	if not rig then return end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	if _activeRagdolls[rig] then return end

	if player then
		Network:FireClient("Jail", player, "LockMovement", {})
		Shared.OnPlayerRagdolled:Fire(player)
	end

	Shared.OnRagdolled:Fire(rig, target)

	humanoid.EvaluateStateMachine = false
	humanoid.PlatformStand = true

	Local.StopAnimations(rig)
	local motorStates = Local.DisableMotors(rig)
	local ballSockets, attachments = Local.AddBallSockets(rig)
	local collisionStates = Local.ApplyRagdollCollisionState(rig)
	Local.SetServerOwnership(rig)

	_activeRagdolls[rig] = {
		rig = rig,
		player = player,
		motorStates = motorStates,
		ballSockets = ballSockets,
		attachments = attachments,
		collisionStates = collisionStates,
		restored = false,
	}

	_destroyingConnections[rig] = rig.Destroying:Once(function()
		Local.CleanupState(rig)
	end)

	Local.ApplyForce(rig, hitPosition, direction, force)
	Local.RunRestoreTimer(rig)
end

function Shared.Restore(target: Player | Model)
	local rig = Local.ResolveTarget(target)
	if not rig then return end

	local state = _activeRagdolls[rig]
	if not state or state.restored then return end

	state.restored = true
	Local.CleanupState(rig)

	local humanoid = rig:FindFirstChildOfClass("Humanoid")

	Local.RemoveBallSockets(state.ballSockets, state.attachments)
	Local.EnableMotors(state.motorStates)
	Local.RestoreCollisionState(state.collisionStates)

	if state.player then
		Local.ResetOwnership(rig)
	else
		Local.SetServerOwnership(rig)
	end

	if humanoid then
		humanoid.PlatformStand = false
		humanoid.EvaluateStateMachine = true
	end

	if state.player then
		Network:FireClient("Jail", state.player, "UnlockMovement", {})
	end
end

function Shared.IsRagdolled(target: Player | Model): boolean
	local rig = Local.ResolveTarget(target)
	if not rig then return false end
	return _activeRagdolls[rig] ~= nil
end

Shared.RagdollPlayer = Shared.Ragdoll
Shared.RestorePlayer = Shared.Restore

return Shared