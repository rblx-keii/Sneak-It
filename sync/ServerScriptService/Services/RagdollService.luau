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

-- Fires for every ragdoll, Player or NPC rig alike (unlike OnPlayerRagdolled,
-- which only fires when the target resolves to an actual Player). Added so
-- NPCAIService has a single "violence witnessed" signal to react to without
-- needing to special-case NPC-on-NPC or player-on-NPC ragdolls separately.
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

-- Accepts either a Player (uses their Character) or a Model (an NPC rig / character model directly).
-- Returns the rig and, if there is one, the owning Player (for client networking).
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

-- Switches every limb to RAGDOLL_COLLISION_GROUP and forces CanCollide on (ragdoll parts are
-- often CanCollide = false by default so they don't collide with anything pre-ragdoll), remembering
-- both original values so they can be restored later. Caller is responsible for registering the
-- group and its collision rules (e.g. collidable with "Default", not with itself, not with players).
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

-- Pins network ownership to the server for the duration of the ragdoll, preventing
-- client/server physics desync (which can otherwise look like jittering).
function Local.SetServerOwnership(rig: Model)
	for _, part in rig:GetDescendants() do
		if part:IsA("BasePart") then
			local ok = pcall(function()
				part:SetNetworkOwner(nil)
			end)
			if not ok then
				-- part may not support manual ownership (e.g. anchored); ignore
			end
		end
	end
end

-- Hands network ownership back to the engine's automatic assignment.
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

		-- Bail if rig was destroyed or restored externally
		if not rig or not rig.Parent then return false end

		if root.AssemblyLinearVelocity.Magnitude < VELOCITY_SETTLE_THRESHOLD then
			return true
		end
	end

	return true -- max time elapsed, proceed to restore
end

function Local.RunRestoreTimer(rig: Model)
	task.spawn(function()
		Local.WaitForSettle(rig)

		-- Check if already restored externally during settle wait
		local state = _activeRagdolls[rig]
		if not state or state.restored then return end

		task.wait(SETTLE_WAIT_SECONDS)

		-- Check again after the settle timer
		state = _activeRagdolls[rig]
		if not state or state.restored then return end

		Shared.Restore(rig)
	end)
end

-- [[ Public Functions ]] --

-- target can be a Player OR an NPC rig (Model with a Humanoid + PrimaryPart)
function Shared.Ragdoll(target: Player | Model, hitPosition: Vector3, direction: Vector3, force: number)
	local rig, player = Local.ResolveTarget(target)
	if not rig then return end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	-- Don't double-ragdoll
	if _activeRagdolls[rig] then return end
	
	-- Lock movement on client (only meaningful if this is an actual Player)
	if player then
		Network:FireClient("Jail", player, "LockMovement", {})
		Shared.OnPlayerRagdolled:Fire(player)
	end

	Shared.OnRagdolled:Fire(rig, target)

	-- Disable Humanoid state machine
	humanoid.EvaluateStateMachine = false
	humanoid.PlatformStand = true

	-- Stop animations, disable motors, add ball sockets, swap collision state, pin ownership
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

	-- NPC rigs don't fire PlayerRemoving, so clean up if they get Destroy()'d mid-ragdoll
	_destroyingConnections[rig] = rig.Destroying:Once(function()
		Local.CleanupState(rig)
	end)

	-- Apply the hit force
	Local.ApplyForce(rig, hitPosition, direction, force)

	-- Start internal restore timer
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

	-- Remove ball sockets before re-enabling motors
	Local.RemoveBallSockets(state.ballSockets, state.attachments)
	Local.EnableMotors(state.motorStates)
	Local.RestoreCollisionState(state.collisionStates)

	-- NPCs have no owning client, so keep them server-pinned instead of
	-- releasing to automatic ownership.
	if state.player then
		Local.ResetOwnership(rig)
	else
		Local.SetServerOwnership(rig)
	end

	-- Restore Humanoid state machine
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.EvaluateStateMachine = true
	end

	-- Unlock movement on client
	if state.player then
		Network:FireClient("Jail", state.player, "UnlockMovement", {})
	end
end

function Shared.IsRagdolled(target: Player | Model): boolean
	local rig = Local.ResolveTarget(target)
	if not rig then return false end
	return _activeRagdolls[rig] ~= nil
end

-- Backwards-compatible aliases in case other code still calls the old names
Shared.RagdollPlayer = Shared.Ragdoll
Shared.RestorePlayer = Shared.Restore

return Shared