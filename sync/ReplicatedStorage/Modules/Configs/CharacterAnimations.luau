--|| Types
export type AnimationOption = {
	id: number,
	weight: number,
}

export type AnimationStateDef = {
	options: { AnimationOption },
	priority: Enum.AnimationPriority,
	looped: boolean,
	isAction: boolean?, -- true for contextual tracks (IdleAction1/2) that layer over the current pose instead of being one themselves
}

--|| MAIN ||--
-- Shared base pose/action set for both Players (CharacterService destroys the
-- default Animate script and drives this instead) and Crowd NPCs
-- (NpcService.SpawnNPC) — played through CharacterController.Setup.
-- Idle/Walk/Run/Jump/Fall/Climb/Sit are mutually-exclusive "pose" states (only
-- one plays at a time, same as Roblox's own default Animate script).
-- IdleAction1/IdleAction2 are contextual — never auto-triggered, callers
-- Play() them whenever they want. Ids for Jump/Fall/Climb/Sit are Roblox's
-- own stock default animations (kept so those poses still look correct);
-- everything else is custom.
local CharacterAnimations: { [string]: AnimationStateDef } = {
	Idle = {
		options = {
			{ id = 129891962822982, weight = 10 }, -- custom
		},
		priority = Enum.AnimationPriority.Idle,
		looped = true,
	},
	Walk = {
		options = { { id = 90128821223962, weight = 10 } }, -- custom
		priority = Enum.AnimationPriority.Idle,
		looped = true,
	},
	Run = {
		options = { { id = 84054275804296, weight = 10 } }, -- custom
		priority = Enum.AnimationPriority.Idle,
		looped = true,
	},
	Jump = {
		options = { { id = 125750702, weight = 10 } }, -- default
		priority = Enum.AnimationPriority.Idle,
		looped = false,
	},
	Fall = {
		options = { { id = 180436148, weight = 10 } }, -- default
		priority = Enum.AnimationPriority.Idle,
		looped = true,
	},
	Climb = {
		options = { { id = 180436334, weight = 10 } }, -- default
		priority = Enum.AnimationPriority.Idle,
		looped = true,
	},
	Sit = {
		options = { { id = 178130996, weight = 10 } }, -- default
		priority = Enum.AnimationPriority.Idle,
		looped = true,
	},
	IdleAction1 = {
		options = { { id = 95901879935494, weight = 10 } }, -- custom
		priority = Enum.AnimationPriority.Action,
		looped = false,
		isAction = true,
	},
	IdleAction2 = {
		options = { { id = 82689668431578, weight = 10 } }, -- custom
		priority = Enum.AnimationPriority.Action,
		looped = false,
		isAction = true,
	},
}

return CharacterAnimations
