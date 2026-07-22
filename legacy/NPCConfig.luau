--|| Types

-- One Primary per Crowd NPC — mutually exclusive, governs the overall
-- movement pattern. Any number of Modifiers can stack independently on top
-- of whichever Primary is active. Decoys roll neither (bespoke behavior).
export type PrimaryTrait = "WalkIn" | "Hasty" | "Loiterer"
export type ModifierTrait = "Weary" | "Caffeinated" | "Thief"

export type PrimaryWeight = {
	name: PrimaryTrait,
	weight: number,
}

--|| MAIN ||--
local NPCConfig = {}

-- [[ Population ]] --
NPCConfig.MAX_NPCS = 10
NPCConfig.MIN_DECOYS = 1
NPCConfig.MAX_DECOYS = 3

-- [[ Movement ]] --
NPCConfig.WALK_SPEED = 14
NPCConfig.WALK_SPEED_JITTER = 1.5 -- +/- studs/s randomized per NPC on spawn, so the crowd doesn't move in lockstep
NPCConfig.OBSTRUCTION_BUFFER = 3 -- studs to stop short of a raycast-detected obstruction (direct-move fallback only)
NPCConfig.ARRIVAL_TOLERANCE = 3 -- studs; how close counts as "reached" a node/waypoint
NPCConfig.NODE_SEARCH_RADIUS = 60 -- Auto-mode nearest-node search radius
NPCConfig.NODE_SPREAD_RADIUS = 4 -- studs; Basic ("Node") arrivals spread across this radius instead of one exact point
NPCConfig.STUCK_TIMEOUT = 8 -- seconds an NPC can be mid-move before it's considered stuck and re-routed

-- [[ Pathfinding ]] --
NPCConfig.PATH_AGENT_RADIUS = 2
NPCConfig.PATH_AGENT_HEIGHT = 5
NPCConfig.PATH_AGENT_CAN_JUMP = false
NPCConfig.PATH_WAYPOINT_SPACING = 4

-- [[ Line node ]] --
NPCConfig.SLOT_SPACING = 4 -- studs between queued NPCs
NPCConfig.LINE_DWELL = 1.5 -- seconds the front-of-line NPC pauses before advancing past the node

-- [[ Seat node ]] --
NPCConfig.SEAT_MIN_DURATION = 10
NPCConfig.SEAT_MAX_DURATION = 30

-- [[ Conveyor node ]] --
NPCConfig.BELT_TRAVEL_TIME = 6
NPCConfig.CONVEYOR_DETECT_RADIUS = 20 -- automated contraband-alert blast radius from the checkpoint node
NPCConfig.CONVEYOR_DETECT_REQUIRE_LOS = false

-- [[ Waiting / Wandering ]] --
NPCConfig.WANDER_RADIUS = 12
NPCConfig.WANDER_INTERVAL_MIN = 3
NPCConfig.WANDER_INTERVAL_MAX = 8

-- [[ Alert / Panic / Contagion ]] --
NPCConfig.ALERT_LOOK_DURATION = 2
NPCConfig.ALERT_ESCALATE_CHANCE = 0.35
NPCConfig.PANIC_DURATION = 6
NPCConfig.PANIC_RADIUS = 25
NPCConfig.CONTAGION_CHANCE = 0.5

-- [[ Decoys ]] --
NPCConfig.DECOY_JAIL_DURATION = 20
NPCConfig.DECOY_DIVERT_COOLDOWN = 15
NPCConfig.DECOY_DIVERT_CHANCE = 0.4

-- [[ Traits (Crowd-kind only — Decoys keep their own bespoke divert behavior
-- above rather than rolling any of these) ]] --

-- Primary: exactly one per Crowd NPC, governs the overall movement pattern.
NPCConfig.PRIMARY_TRAIT_WEIGHTS = {
	{ name = "WalkIn", weight = 40 },
	{ name = "Hasty", weight = 30 },
	{ name = "Loiterer", weight = 30 },
} :: { PrimaryWeight }

-- Modifiers: each rolled independently, so an NPC can end up with none, one,
-- or all three stacked on top of its Primary.
NPCConfig.MODIFIER_CHANCE = {
	Weary = 0.35,
	Caffeinated = 0.3,
	Thief = 0.25,
} :: { [ModifierTrait]: number }

-- Line Impatience: applies to every queued Crowd NPC — ticks up while
-- waiting behind the front of the line, and once it crosses the threshold
-- the NPC gives up on the line, resolving to either seek a seat or leave the
-- airport outright.
NPCConfig.IMPATIENCE_ROLL_INTERVAL = 5 -- seconds between impatience ticks
NPCConfig.IMPATIENCE_THRESHOLD = 5 -- accumulated ticks (at multiplier 1) before giving up
NPCConfig.IMPATIENCE_SEAT_CHANCE = 0.6 -- once given up: chance to seek a seat instead of leaving outright
NPCConfig.IMPATIENCE_PRIMARY_MULTIPLIER = {
	WalkIn = 2, -- impatient — this is their whole gimmick
	Hasty = 0.2, -- persistent, rarely gives up on anything between it and the gate
	Loiterer = 1,
} :: { [PrimaryTrait]: number }
NPCConfig.IMPATIENCE_WEARY_BONUS = 0.5 -- additive, on top of the Primary multiplier, if Weary is stacked on

-- Rest / Wander: the shared default behavior most Primaries fall back to at
-- each node arrival (everything except Loiterer, which never proceeds
-- normally, and Hasty, which skips this step entirely).
NPCConfig.REST_CHANCE = 0.3 -- baseline chance to seek a seat instead of proceeding
NPCConfig.WEARY_REST_CHANCE = 0.7 -- rolled instead of REST_CHANCE when Weary is stacked on
NPCConfig.REST_SEARCH_TIMEOUT = 6 -- seconds to look for a free seat before giving up and proceeding
NPCConfig.WANDER_CHANCE = 0.3 -- chance to locally wander instead of proceeding (rolled if Rest didn't trigger)
NPCConfig.WANDER_INTERACT_CHANCE = 0.5 -- while locally wandering, chance to detour into a nearby Interaction node
NPCConfig.LOCAL_WANDER_RADIUS = 15 -- studs, for the previous/current/next-node loiter loop

-- Interaction / Stand nodes — cosmetic dwell points.
NPCConfig.INTERACTION_DWELL_MIN = 4
NPCConfig.INTERACTION_DWELL_MAX = 12
NPCConfig.STAND_DWELL_MIN = 5
NPCConfig.STAND_DWELL_MAX = 15

-- Caffeinated (modifier): periodically diverts toward a Cafe-location node;
-- once it leaves the Cafe zone it gets a permanent speed boost and reacts to
-- Alert/Panic more readily for the rest of the round.
NPCConfig.CAFFEINE_DIVERT_COOLDOWN = 20
NPCConfig.CAFFEINE_DIVERT_CHANCE = 0.5
NPCConfig.CAFFEINE_SPEED_MULTIPLIER = 1.35
NPCConfig.CAFFEINE_ALERT_ESCALATE_CHANCE = 0.75 -- overrides ALERT_ESCALATE_CHANCE once boosted

-- Thief (modifier): periodically targets a nearby Crowd NPC's held item.
NPCConfig.THIEF_STEAL_COOLDOWN = 12
NPCConfig.THIEF_STEAL_CHANCE = 0.4
NPCConfig.THIEF_STEAL_RANGE = 40 -- search radius for a victim
NPCConfig.THIEF_APPROACH_DURATION = 2 -- seconds spent "stealing" once in position, before the item transfers

-- [[ Brain Actor (parallel Luau AI decisions) ]] --
NPCConfig.BRAIN_SCRIPT_PATH = { "NPCBrain", "NPCBrainScript" } -- ServerScriptService.NPCBrain.NPCBrainScript
NPCConfig.DECISION_TIMEOUT = 3 -- seconds to wait for a brain Actor's response before falling back to Proceed

-- [[ Assets ]] --
NPCConfig.RIG_TEMPLATE_PATH = { "Assets", "Rig" } -- ReplicatedStorage.Assets.Rig
NPCConfig.DEFAULT_BAG_ITEM = "DuffleBag" -- item name in ItemsConfig / Assets.Items, given to crowd NPCs on spawn
NPCConfig.DECOY_BAIT_ITEM = "Passport" -- contraband item Decoys hold directly so they read HasContraband to a scan

return NPCConfig
