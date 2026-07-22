--|| ProjectileSimulation
-- Centralized module exposing two signal-driven projectile classes:
--
--   .Projectile  — fast, straight-line, instant-travel visual (e.g. darts, blasts).
--                  Client spawns this for visual travel only; fires onHit when it
--                  reaches its target position, where you connect VFX/hit-reaction logic.
--
--   .Ricochet    — gravity-affected, bouncing arc (e.g. thrown bombs). Raycasts each
--                  step to detect surface bounces, reflects velocity off the normal,
--                  fires onHit once when it comes to rest OR its lifetime expires.
--
-- Both classes are pure simulation/visual — they do NOT make network calls themselves.
-- The calling code (ItemsConfig modules, weapon scripts, etc.) is responsible for
-- firing whatever Network event is needed inside the onHit callback, matching the
-- client-detects → server-validates pattern used elsewhere in this project.
--
-- Bullet templates under ReplicatedStorage.Assets.Bullets may be either a BasePart
-- (used directly) or a Model (must have PrimaryPart set — every other BasePart
-- descendant gets welded to it so the whole model rides along as one rigid unit).

--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--|| References
local ModuleUtils = require(ReplicatedStorage.Modules.Utils.ModuleUtils)

--|| MAIN ||--
local ProjectileSimulation = {}

--|| Local ||--
local Local = {}

-- Clones a bullet template (BasePart or Model) and prepares it for per-frame
-- kinematic driving. Returns the root instance to parent/destroy, and the
-- single BasePart whose CFrame the simulation steps drive each frame.
--
-- BasePart template: root and driving part are the same instance.
-- Model template: PrimaryPart becomes the driving part; every other BasePart
--   descendant is welded to it (Anchored = false, CanCollide = false) while
--   PrimaryPart itself is Anchored so it can be pushed by CFrame each step.
--   If the Model has no PrimaryPart set, warns and falls back to the same
--   placeholder part used when no template is found at all.
function Local.InstantiateBullet(name: string): (Instance, BasePart)
	local template = ReplicatedStorage.Assets.Bullets:FindFirstChild(name)
	if not template then
		warn(`[ProjectileSimulation] No bullet template found for "{name}" in ReplicatedStorage.Assets.Bullets`)
		return Local.MakePlaceholder()
	end

	if template:IsA("BasePart") then
		local part = template:Clone() :: BasePart
		part.Anchored = true
		part.CanCollide = false
		return part, part
	end

	if template:IsA("Model") then
		if not template.PrimaryPart then
			warn(`[ProjectileSimulation] Bullet model "{name}" has no PrimaryPart set — using a placeholder part instead`)
			return Local.MakePlaceholder()
		end

		local root = template:Clone() :: Model
		local primaryPart = root.PrimaryPart :: BasePart

		primaryPart.Anchored = true
		primaryPart.CanCollide = false

		for _, descendant in root:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= primaryPart then
				descendant.Anchored = false
				descendant.CanCollide = false

				local weld = Instance.new("WeldConstraint")
				weld.Part0 = primaryPart
				weld.Part1 = descendant
				weld.Parent = descendant
			end
		end

		return root, primaryPart
	end

	warn(`[ProjectileSimulation] Bullet template "{name}" is neither a BasePart nor a Model — using a placeholder part instead`)
	return Local.MakePlaceholder()
end

function Local.MakePlaceholder(): (BasePart, BasePart)
	local part = Instance.new("Part")
	part.Size = Vector3.new(0.5, 0.5, 0.5)
	part.Anchored = true
	part.CanCollide = false
	return part, part
end

function Local.SetTransparency(root: Instance, transparency: number)
	if root:IsA("BasePart") then
		root.Transparency = transparency
		return
	end

	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = transparency
		end
	end
end

----------------------------------------------------------------------------------------------------
--|| PROJECTILE ||--
-- Fast, straight-line, constant-speed travel from origin to a known target position.
-- Used for hitscan-style visuals where the hit result is already known (server raycast
-- resolved upfront, or client-detected and pending server validation).
----------------------------------------------------------------------------------------------------

local Projectile = {}
Projectile.__index = Projectile

export type Projectile = typeof(setmetatable(
	{} :: {
		_speed: number,
		_timeLeft: number,

		_origin: Vector3,
		_position: Vector3,
		_target: Vector3,

		_raycastParams: RaycastParams,
		_radius: number,

		onHit: typeof(ModuleUtils.signal.new()),

		_root: Instance,
		_part: BasePart,
		_connection: RBXScriptConnection,
	},
	Projectile
	))

-- name: the BasePart or Model template name under Resources.Bullets to clone for the visual
-- position: world-space spawn position (muzzle/origin)
-- target: world-space resolved hit position (used as a travel bound/fallback, no longer
--          assumed to be what actually gets hit — see per-step raycast below)
-- speed: studs/second travel speed (optional, defaults to 1000)
-- startTime: optional server timestamp, see previous docs
-- raycastParams: optional RaycastParams for the per-step obstruction check (should exclude
--                the shooter's character at minimum). Defaults to a params with no filter.
-- radius: bounding radius added to each step's raycast so the dart doesn't clip through
--         thin geometry at high speed (defaults to 0.25)
function Projectile.new(
	name: string,
	position: Vector3,
	target: Vector3,
	speed: number?,
	startTime: number?,
	raycastParams: RaycastParams?,
	radius: number?
): Projectile
	local self = setmetatable({}, Projectile) :: Projectile

	self._origin = position
	self._target = target
	self._speed = speed or 1000
	self._raycastParams = raycastParams or RaycastParams.new()
	self._radius = radius or 0.25

	self.onHit = ModuleUtils.signal.new()

	local root, drivingPart = Local.InstantiateBullet(name)
	self._root = root
	self._part = drivingPart

	local distance = (target - position).Magnitude
	self._timeLeft = distance / self._speed
	self._position = position

	if startTime then
		local elapsed = math.max(0, Workspace:GetServerTimeNow() - startTime)
		if elapsed > 0 and distance > 0 then
			local direction = (target - position).Unit
			local traveled = math.min(elapsed * self._speed, distance)
			self._position = position + direction * traveled
			self._timeLeft -= elapsed
		end
	end

	-- Parent BEFORE moving the driving part: WeldConstraints capture their
	-- relative offset the moment both parts are in the DataModel. If we move
	-- the primary part first, the weld locks in the (wrong) offset between
	-- "primary part at spawn position" and "descendant still at template
	-- pose", leaving welded parts stranded. Parenting first means the weld
	-- activates while everything is still in its correct relative pose.
	self._root.Parent = Workspace.Debris.Projectiles
	self._part.CFrame = CFrame.lookAt(self._position, self._target)

	Local.SetTransparency(self._root, 0)

	self._connection = RunService.PostSimulation:Connect(function(deltaTime: number)
		self:_step(deltaTime)
	end)

	return self
end

function Projectile._step(self: Projectile, deltaTime: number)
	local toTarget = self._target - self._position
	if toTarget.Magnitude < 0.01 then
		self.onHit:Fire(nil)
		self:Destroy()
		return
	end

	local direction = toTarget.Unit
	local move = direction * self._speed * deltaTime

	-- Raycast THIS FRAME'S segment (with a small radius pad) before committing the move,
	-- so anything that steps into the dart's path mid-flight actually gets hit instead of
	-- the dart sailing through to its originally-resolved target.
	local rayDistance = move.Magnitude + self._radius
	local raycastResult = Workspace:Raycast(self._position, direction * rayDistance, self._raycastParams)

	if raycastResult then
		self._position = raycastResult.Position
		self._part.CFrame = CFrame.lookAt(self._position, self._position + direction)

		self.onHit:Fire(raycastResult)
		self:Destroy()
		return
	end

	self._position += move
	self._part.CFrame = CFrame.lookAt(self._position, self._position + direction)

	self._timeLeft -= deltaTime

	if self._timeLeft <= 0 then
		self.onHit:Fire(nil)
		self:Destroy()
	end
end

function Projectile.Destroy(self: Projectile)
	if self._connection then
		self._connection:Disconnect()
	end
	self.onHit:DisconnectAll()
	if self._root then
		self._root:Destroy()
	end
end

ProjectileSimulation.Projectile = Projectile

----------------------------------------------------------------------------------------------------
--|| RICOCHET ||--
-- Gravity-affected arc with bounce-off-surface-normal physics. Raycasts each step to
-- detect collisions, reflects velocity scaled by elasticity. Used for thrown bombs
-- (Dynamite, Stink Bomb) where the player needs to see real bounce behavior.
--
-- Fires onHit exactly ONCE: either when the projectile comes to rest (velocity below
-- a settle threshold after a bounce) or when its max lifetime expires, whichever first.
----------------------------------------------------------------------------------------------------

local Ricochet = {}
Ricochet.__index = Ricochet

export type Ricochet = typeof(setmetatable(
	{} :: {
		_position: Vector3,
		_velocity: Vector3,
		_gravity: Vector3,
		_elasticity: number,
		_radius: number,

		_elapsed: number,
		_maxLifetime: number,
		_settleThreshold: number,

		_raycastParams: RaycastParams,

		_hasFired: boolean,
		onHit: typeof(ModuleUtils.signal.new()),

		_root: Instance,
		_part: BasePart,
		_connection: RBXScriptConnection,
	},
	Ricochet
	))

type RicochetOptions = {
	name: string,                       -- BasePart or Model template name under Resources.Bullets
	origin: Vector3,
	initialVelocity: Vector3,
	gravity: Vector3?,                  -- defaults to {0, -50, 0}
	elasticity: number?,                -- 0-1, defaults to 0.5
	radius: number?,                    -- bounding radius for collision offset, defaults to 0.5
	maxLifetime: number?,               -- hard cap in seconds, defaults to 8
	settleThreshold: number?,           -- velocity magnitude below which it's considered "at rest", defaults to 1
	raycastParams: RaycastParams?,
	startTime: number?,                 -- optional server timestamp (Workspace:GetServerTimeNow())
	-- the throw actually happened at. If provided, the sim is
	-- fast-forwarded (bounces and all) to the current time before
	-- the live per-frame loop starts, so late observers see the
	-- bomb already mid-flight/mid-bounce instead of restarting.
}

-- Fixed timestep used only for the catch-up simulation below. Small enough that a
-- fast-moving bomb won't tunnel through geometry between raycasts.
local CATCHUP_STEP = 1 / 60

function Ricochet.new(options: RicochetOptions): Ricochet
	local self = setmetatable({}, Ricochet) :: Ricochet

	self._position = options.origin
	self._velocity = options.initialVelocity
	self._gravity = options.gravity or Vector3.new(0, -50, 0)
	self._elasticity = math.clamp(options.elasticity or 0.5, 0, 1)
	self._radius = options.radius or 0.5

	self._elapsed = 0
	self._maxLifetime = options.maxLifetime or 8
	self._settleThreshold = options.settleThreshold or 1

	-- Build our own RaycastParams instead of holding a reference to the caller's — we need
	-- to force RespectCanCollide on, and mutating a shared/passed-in object in place could
	-- unexpectedly change behavior elsewhere it's reused.
	local raycastParams = RaycastParams.new()
	if options.raycastParams then
		raycastParams.FilterType = options.raycastParams.FilterType
		raycastParams.FilterDescendantsInstances = options.raycastParams.FilterDescendantsInstances
		raycastParams.IgnoreWater = options.raycastParams.IgnoreWater
	end
	raycastParams.RespectCanCollide = true
	self._raycastParams = raycastParams

	self._hasFired = false

	self.onHit = ModuleUtils.signal.new()

	local root, drivingPart = Local.InstantiateBullet(options.name)
	self._root = root
	self._part = drivingPart

	-- Parent BEFORE moving the driving part — see the comment in
	-- Projectile.new for why ordering matters here.
	self._root.Parent = Workspace.Debris.Projectiles
	self._part.CFrame = CFrame.new(self._position)

	Local.SetTransparency(self._root, 0)

	if options.startTime then
		local elapsed = math.max(0, Workspace:GetServerTimeNow() - options.startTime)
		local remaining = elapsed

		while remaining > 0 and not self._hasFired do
			local dt = math.min(CATCHUP_STEP, remaining)
			self:_step(dt)
			remaining -= dt
		end
	end

	if self._hasFired then
		return self
	end

	self._connection = RunService.PostSimulation:Connect(function(deltaTime: number)
		self:_step(deltaTime)
	end)

	return self
end

function Ricochet._step(self: Ricochet, deltaTime: number)
	if self._hasFired then return end

	self._elapsed += deltaTime

	-- Hard lifetime cap — fire onHit at current position regardless of velocity
	if self._elapsed >= self._maxLifetime then
		self:_fireHit()
		return
	end

	local accelerationMultiplier = 0.5
	local displacement = (self._velocity * deltaTime) + (self._gravity * accelerationMultiplier * (deltaTime * deltaTime))

	if displacement.Magnitude < 0.001 then
		-- No meaningful movement this frame (e.g. resting on a surface already)
		self._part.CFrame = CFrame.new(self._position)
		return
	end

	local rayDir = displacement.Unit * (displacement.Magnitude + self._radius)
	local raycastResult = Workspace:Raycast(self._position, rayDir, self._raycastParams)

	if raycastResult then
		local surfaceNormal = raycastResult.Normal
		self._position = raycastResult.Position + (surfaceNormal * self._radius)

		local impactVelocity = self._velocity + (self._gravity * deltaTime)
		local reflectedVelocity = impactVelocity - (2 * impactVelocity:Dot(surfaceNormal) * surfaceNormal)

		self._velocity = reflectedVelocity * self._elasticity

		self._part.CFrame = CFrame.new(self._position)

		-- Settled — velocity dropped below threshold after this bounce
		if self._velocity.Magnitude < self._settleThreshold then
			self:_fireHit()
		end

		return
	end

	-- No collision this step — continue free-falling
	self._velocity += self._gravity * deltaTime
	self._position += displacement
	self._part.CFrame = CFrame.new(self._position)
end

function Ricochet._fireHit(self: Ricochet)
	if self._hasFired then return end
	self._hasFired = true

	self.onHit:Fire(self:GetPosition())
	self:Destroy()
end

function Ricochet.GetPosition(self: Ricochet): Vector3
	return self._position
end

function Ricochet.GetVelocity(self: Ricochet): Vector3
	return self._velocity
end

function Ricochet.Destroy(self: Ricochet)
	if self._connection then
		self._connection:Disconnect()
	end
	self.onHit:DisconnectAll()
	if self._root then
		self._root:Destroy()
	end
end

ProjectileSimulation.Ricochet = Ricochet

return ProjectileSimulation