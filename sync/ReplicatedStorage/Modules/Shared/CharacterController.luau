--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local CharacterAnimations = require(ReplicatedStorage.Modules.Configs.CharacterAnimations)

--|| Types
export type AnimationSet = { [string]: AnimationTrack }

type PoolEntry = { track: AnimationTrack, weight: number }

--|| Constants
local IDLE_SPEED_THRESHOLD = 0.5 -- studs/s; Humanoid.Running reports current speed, below this counts as standing still
local RUN_SPEED_THRESHOLD = 20 -- studs/s; no sprint mechanic exists yet, so ordinary WalkSpeed (NPCConfig ~14, default player ~16) always resolves to Walk — tune once a sprint speed exists
local REFERENCE_WALK_SPEED = 16 -- studs/s the Walk/Run clips are authored for; playback speed is scaled against this so foot-planting still matches actual Humanoid.WalkSpeed (NPCConfig jitters this per-NPC)
local RUN_CONFIRM_READINGS = 2 -- consecutive above-threshold readings required before committing to Run, filters single-frame spikes
local ADJUST_SPEED_MAX_RATIO = 1.5 -- hard ceiling on Walk/Run playback speed
local DEFAULT_FADE_TIME = 0.2
local FADE_TIMES: { [string]: number } = {
	Idle = 0.1,
	Walk = 0.1,
	Run = 0.1,
	Jump = 0.1,
	Fall = 0.3,
	Climb = 0.1,
	Sit = 0.5,
}

--|| MAIN ||--
local CharacterController = {}

-- [[ Private ]] --
local function RollTrack(pool: { PoolEntry }): AnimationTrack
	local totalWeight = 0
	for _, entry in pool do
		totalWeight += entry.weight
	end

	local roll = math.random() * totalWeight
	for _, entry in pool do
		roll -= entry.weight
		if roll <= 0 then
			return entry.track
		end
	end
	return pool[#pool].track
end

-- [[ Public ]] --

-- Full custom Animate-script replacement — used for both Players
-- (CharacterService destroys the default Animate script and calls this
-- instead) and Crowd NPCs (NpcService.SpawnNPC), so both rig types drive
-- their base pose off the same CharacterAnimations config. Idle/Walk/Run/
-- Jump/Fall/Climb/Sit are mutually exclusive — only one plays at a time,
-- swapped off Humanoid state events, matching how Roblox's own default
-- Animate script behaves. Returns just the IdleAction1/IdleAction2 tracks;
-- those are never auto-played — callers Play() them contextually (e.g.
-- during a shop/line dwell) and they fall away on their own once finished,
-- since they're loaded at Action priority, above the current pose.
function CharacterController.Setup(humanoid: Humanoid): AnimationSet
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)

	local poolsByState: { [string]: { PoolEntry } } = {}
	local actionTracks: AnimationSet = {}

	for name, def in CharacterAnimations do
		local pool: { PoolEntry } = {}
		for _, option in def.options do
			local animation = Instance.new("Animation")
			animation.AnimationId = `rbxassetid://{option.id}`

			local track = animator:LoadAnimation(animation)
			track.Priority = def.priority
			track.Looped = def.looped
			table.insert(pool, { track = track, weight = option.weight })
		end

		if def.isAction then
			actionTracks[name] = pool[1].track
		else
			poolsByState[name] = pool
		end
	end

	local currentPoseName: string? = nil
	local currentPoseTrack: AnimationTrack? = nil
	local aboveRunThresholdStreak = 0

	local function PlayPose(name: string)
		if name == currentPoseName then
			return
		end

		local fadeTime = FADE_TIMES[name] or DEFAULT_FADE_TIME
		if currentPoseTrack then
			currentPoseTrack:Stop(fadeTime)
		end

		currentPoseTrack = RollTrack(poolsByState[name])
		currentPoseTrack:Play(fadeTime)
		currentPoseName = name
	end

	humanoid.Running:Connect(function(speed: number)
		if humanoid:GetState() == Enum.HumanoidStateType.Seated then
			return
		end

		if speed > RUN_SPEED_THRESHOLD then
			aboveRunThresholdStreak += 1
		else
			aboveRunThresholdStreak = 0
		end

		local poseName: string
		if aboveRunThresholdStreak >= RUN_CONFIRM_READINGS then
			poseName = "Run"
		elseif speed > IDLE_SPEED_THRESHOLD then
			poseName = "Walk"
		else
			poseName = "Idle"
		end

		PlayPose(poseName)

		if (poseName == "Walk" or poseName == "Run") and currentPoseTrack then
			currentPoseTrack:AdjustSpeed(math.clamp(speed / REFERENCE_WALK_SPEED, 0, ADJUST_SPEED_MAX_RATIO))
		end
	end)

	humanoid.Jumping:Connect(function()
		PlayPose("Jump")
	end)

	humanoid.FreeFalling:Connect(function(active: boolean)
		if active then
			PlayPose("Fall")
		end
	end)

	humanoid.Climbing:Connect(function()
		PlayPose("Climb")
	end)

	humanoid.Seated:Connect(function(active: boolean)
		if active then
			PlayPose("Sit")
		end
	end)

	PlayPose("Idle")

	return actionTracks
end

return CharacterController
