--|| MAIN ||--
local NPCConfig = {}

-- [[ Population ]] --
NPCConfig.MAX_NPCS = 30
NPCConfig.DEFAULT_BAG_ITEM = "DuffleBag" -- item name in ItemsConfig / Assets.Items, given to crowd NPCs on spawn
NPCConfig.BAG_SPAWN_CHANCE = 0.75 -- chance a Crowd NPC spawns already holding a bag, rolled once per spawn

-- [[ Movement ]] --
NPCConfig.WALK_SPEED = 14
NPCConfig.WALK_SPEED_JITTER = 1.5 -- +/- studs/s randomized per NPC on spawn, so the crowd doesn't move in lockstep
NPCConfig.OBSTRUCTION_BUFFER = 3 -- studs to stop short of a raycast-detected obstruction (direct-move fallback only)
NPCConfig.ARRIVAL_TOLERANCE = 3 -- studs; how close counts as "reached" a node/waypoint
NPCConfig.NODE_SEARCH_RADIUS = 150 -- Auto-search candidate radius (currently unused by distance cutoff, kept for tuning)
NPCConfig.NODE_SPREAD_RADIUS = 10 -- studs; Basic ("Node") arrivals spread across this radius instead of one exact point
NPCConfig.DEPART_NODE_SPREAD_RADIUS = 1.5 -- studs; tighter cap on the above specifically for Depart Folder nodes (narrow gate corridor — the full spread can land inside a wall/doorframe)
NPCConfig.STUCK_TIMEOUT = 15 -- seconds a single waypoint leg can run past its own expected duration before it's given up on and rerouted to a different node entirely
NPCConfig.LEG_TIMEOUT_GRACE_MULTIPLIER = 1.5 -- a leg's expected duration (distance/WalkSpeed) times this before the nudge-recovery cycle kicks in at all
NPCConfig.STUCK_NUDGE_DISTANCE = 0.4 -- studs to nudge the NPC toward its current waypoint on the first stuck attempt (also the STUCK_PROGRESS_RATIO baseline)
NPCConfig.STUCK_NUDGE_BACK_DISTANCE = 1 -- studs stepped backward (away from current facing) when a back+side recovery nudge fires, to clear corner/edge snags a straight-toward-goal push can't
NPCConfig.STUCK_NUDGE_SIDE_DISTANCE = 1 -- studs stepped sideways, toward whichever side is closer to the goal, alongside the backward step
NPCConfig.STUCK_BACKSIDE_NUDGE_COOLDOWN = 2 -- seconds between back+side nudges; only considered once a plain toward-goal nudge alone has failed to make progress
NPCConfig.STUCK_NUDGE_CHECK_INTERVAL = 0.5 -- seconds between nudge-recovery progress probes
NPCConfig.STUCK_PROGRESS_RATIO = 0.5 -- fraction of STUCK_NUDGE_DISTANCE that counts as "made real progress" since the last probe (skips nudging, extends the leg's budget instead)
NPCConfig.PREFETCH_DRIFT_TOLERANCE = 10 -- studs; beyond this drift from a prefetched leg's assumed start, stale waypoints are discarded and repathed fresh
NPCConfig.DECISION_TIMEOUT = 1.5 -- TEMP: lowered from 3 for faster feedback while debugging pathfinding — seconds to wait for the brain Actor's decision report before retrying (covers a lost/crashed report)
NPCConfig.REST_COOLDOWN = 20 -- seconds after resting at a Seat Node before an NPC will consider sitting again (Seat Node candidates are skipped during Auto-search until this elapses)
NPCConfig.SEAT_REST_DURATION = 5 -- seconds an NPC must stay seated at a Seat Node before it will stand up and request its next decision
NPCConfig.SEAT_RETRY_CHANCE = 0.5 -- chance to keep looking for another open seat when the nearest one is occupied, instead of giving up and continuing on
NPCConfig.UNSEAT_MAX_ATTEMPTS = 10 -- retries for confirming a Seat's occupant actually released (Seat:Sit(nil)/Humanoid.Sit=false can lag a frame or more) before giving up
NPCConfig.SEAT_STAND_CLEAR_DISTANCE = 4 -- studs a just-stood NPC walks straight out from the seat (along the Seat's LookVector) before taking a real decision, so it doesn't cut across neighboring seats
NPCConfig.SEAT_STAND_CLEAR_TIMEOUT = 3 -- seconds to wait for that clear-walk to finish before giving up and moving on anyway

-- [[ Pathfinding ]] --
NPCConfig.PATH_AGENT_RADIUS = 2.5
NPCConfig.PATH_AGENT_HEIGHT = 5
NPCConfig.PATH_AGENT_CAN_JUMP = false
NPCConfig.PATH_AGENT_CAN_CLIMB = false
NPCConfig.PATH_WAYPOINT_SPACING = 15 -- studs; wide enough to avoid re-issuing Humanoid:MoveTo() every few studs (which visibly hitched the walk animation), but frequent enough that long straight-line legs don't clip through walls the navmesh only avoids at the corner waypoints

-- [[ Line Node slots ]] --
NPCConfig.LINE_SLOT_PLAYER_RADIUS = 7 -- studs; a live player standing this close to a slot counts as occupying it
NPCConfig.LINE_DWELL_MIN = 5 -- seconds an NPC lingers at the front Line Node before advancing past it
NPCConfig.LINE_DWELL_MAX = 10
NPCConfig.LINE_PREFER_NEAREST_DISTANCE_THRESHOLD = 40 -- studs; how much farther a less-crowded line can be before it's "too far" and the distance-vs-crowd roll kicks in
NPCConfig.LINE_PREFER_NEAREST_CHANCE = 0.5 -- when the less-crowded line is too far, chance to wait at the nearer/busier one instead of walking to it (per request: keep within 0.35-0.65)

-- [[ Zone graph ]] --
NPCConfig.ZONE_ADJACENCY = {
	{ "Lobby", "Concourse" },
	{ "Concourse", "Cafe" },
	{ "Concourse", "Souvenir" },
	{ "Concourse", "Convenience" },
	{ "Concourse", "Platform" },
	{ "Platform", "Depart" },
}

NPCConfig.LINEAR_ZONE_SEQUENCE = { "Lobby", "Concourse", "Platform", "Depart" }
NPCConfig.SHOP_ZONES = { "Cafe", "Souvenir", "Convenience" } -- zones that confine Wander to themselves and track live NPC occupancy

NPCConfig.SHOP_DWELL_MIN = 15 -- seconds an NPC roams/sits in a shop (a Transition Node linked to another Transition Node) before heading back
NPCConfig.SHOP_DWELL_MAX = 30

NPCConfig.SHOP_PICK_WEIGHTS = { Cafe = 1, Souvenir = 1, Convenience = 1 } -- flat by default; pre-picked once per shop-detour roll
NPCConfig.CAFFEINATED_CAFE_WEIGHT_MULTIPLIER = 3 -- Caffeinated NPCs are this many times likelier to pick Cafe over the other two shops

-- [[ Concourse Loitering ]] --
NPCConfig.CONCOURSE_LOITER_CHANCE = 0.55 -- chance a Concourse "Node" arrival detours into a shop/wander/seat/forward-anyway roll instead of always progressing toward Platform, rolled once per Concourse visit
-- Sub-roll weights once the above succeeds — must sum to 1. Remainder after Shop+Wander+Seat is "keep heading toward the next zone anyway".
NPCConfig.CONCOURSE_LOITER_SHOP_WEIGHT = 0.35
NPCConfig.CONCOURSE_LOITER_WANDER_WEIGHT = 0.25
NPCConfig.CONCOURSE_LOITER_SEAT_WEIGHT = 0.25
NPCConfig.CONCOURSE_WANDER_MIN = 25 -- seconds spent wandering Concourse-only when the loiter roll picks "wander" (or falls back to it from a failed shop/seat search)
NPCConfig.CONCOURSE_WANDER_MAX = 45

-- [[ Boarding (GateService integration) ]] --
NPCConfig.BOARD_DWELL = .5 -- seconds an NPC lingers at the Depart Node, once boarding is open, before despawning ("boarding the plane")
NPCConfig.RESPAWN_DELAY_MIN = 5 -- seconds after a boarded NPC despawns before its replacement spawns, randomized in this range
NPCConfig.RESPAWN_DELAY_MAX = 10
NPCConfig.BOARD_ROLL_CHANCE = 1 -- chance an NPC decides to board once the plane has arrived, rolled once per boarding window; the rest keep waiting for a later flight

-- [[ Alert / Panic / Contagion ]] --
NPCConfig.ALERT_LOOK_DURATION = 2 -- seconds an NPC pauses to "look" before rolling to escalate into Panic or calm back down
NPCConfig.ALERT_ESCALATE_CHANCE = 0.35 -- chance an Alert escalates into full Panic once the look duration elapses
NPCConfig.PANIC_DURATION = 6 -- seconds an NPC stays Panicking before calming back down
NPCConfig.PANIC_RADIUS = 25 -- studs; both the erratic-wander range while panicking and ForcePanic's default trigger radius
NPCConfig.CONTAGION_CHANCE = 0.5 -- chance a panicking NPC's nearby (LoS-gated) neighbors also start panicking
NPCConfig.PANIC_SPEED_MULTIPLIER = 1.6 -- WalkSpeed multiplier applied for the duration of Panicking, so fleeing actually reads as running
NPCConfig.PANIC_FLEE_CONE_ANGLE = math.rad(70) -- +/- randomization around the dead-away-from-source direction, so fleeing looks organic instead of laser-straight

-- [[ Ambient Sprinting ]] --
-- Purely cosmetic crowd variety (someone's late for their flight) — unrelated to Alert/Panic, though
-- Panic's speed multiplier always wins over a casual sprint if both are somehow active (see RefreshWalkSpeed).
NPCConfig.SPRINT_CHECK_INTERVAL_MIN = 8 -- seconds between random-sprint rolls per NPC
NPCConfig.SPRINT_CHECK_INTERVAL_MAX = 15
NPCConfig.SPRINT_CHANCE = .325 -- chance each roll starts a sprint burst
NPCConfig.SPRINT_DURATION_MIN = 2 -- seconds a sprint burst lasts
NPCConfig.SPRINT_DURATION_MAX = 5
NPCConfig.SPRINT_SPEED_MULTIPLIER = 2 -- WalkSpeed multiplier while sprinting

-- [[ Conveyor node (bag-in-transit) ]] --
NPCConfig.BELT_TRAVEL_TIME = 3 -- seconds a dropped bag takes to visually ride from a Conveyor Node to its linked exit node

-- [[ Assets ]] --
NPCConfig.RIG_TEMPLATE_PATH = { "Assets", "Rig" } -- ReplicatedStorage.Assets.Rig

return NPCConfig
