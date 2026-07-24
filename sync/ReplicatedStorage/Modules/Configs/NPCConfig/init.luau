--|| MAIN ||--
local NPCConfig = {}

-- [[ Population ]] --
NPCConfig.MAX_NPCS = 10

-- [[ Movement ]] --
NPCConfig.WALK_SPEED = 14
NPCConfig.WALK_SPEED_JITTER = 1.5 -- +/- studs/s randomized per NPC on spawn, so the crowd doesn't move in lockstep
NPCConfig.OBSTRUCTION_BUFFER = 3 -- studs to stop short of a raycast-detected obstruction (direct-move fallback only)
NPCConfig.ARRIVAL_TOLERANCE = 3 -- studs; how close counts as "reached" a node/waypoint
NPCConfig.NODE_SEARCH_RADIUS = 150 -- Auto-search candidate radius (currently unused by distance cutoff, kept for tuning)
NPCConfig.NODE_SPREAD_RADIUS = 10 -- studs; Basic ("Node") arrivals spread across this radius instead of one exact point
NPCConfig.DEPART_NODE_SPREAD_RADIUS = 1.5 -- studs; tighter cap on the above specifically for Depart Folder nodes (narrow gate corridor — the full spread can land inside a wall/doorframe)
NPCConfig.STUCK_TIMEOUT = 8 -- seconds a single waypoint leg can run past its own expected duration before it's given up on and force-arrived
NPCConfig.LEG_TIMEOUT_GRACE_MULTIPLIER = 1.5 -- a leg's expected duration (distance/WalkSpeed) times this before the nudge-recovery cycle kicks in at all
NPCConfig.STUCK_NUDGE_DISTANCE = 0.4 -- studs to physically nudge the NPC toward its current waypoint each probe, when it isn't making real progress on its own
NPCConfig.STUCK_NUDGE_CHECK_INTERVAL = 0.5 -- seconds between nudge-recovery progress probes
NPCConfig.STUCK_PROGRESS_RATIO = 0.5 -- fraction of STUCK_NUDGE_DISTANCE that counts as "made real progress" since the last probe (skips nudging, extends the leg's budget instead)
NPCConfig.PREFETCH_DRIFT_TOLERANCE = 10 -- studs; beyond this drift from a prefetched leg's assumed start, stale waypoints are discarded and repathed fresh
NPCConfig.DECISION_TIMEOUT = 1.5 -- TEMP: lowered from 3 for faster feedback while debugging pathfinding — seconds to wait for the brain Actor's decision report before retrying (covers a lost/crashed report)
NPCConfig.REST_COOLDOWN = 20 -- seconds after resting at a Seat Node before an NPC will consider sitting again (Seat Node candidates are skipped during Auto-search until this elapses)
NPCConfig.SEAT_REST_DURATION = 5 -- seconds an NPC must stay seated at a Seat Node before it will stand up and request its next decision
NPCConfig.SEAT_RETRY_CHANCE = 0.5 -- chance to keep looking for another open seat when the nearest one is occupied, instead of giving up and continuing on

-- [[ Pathfinding ]] --
NPCConfig.PATH_AGENT_RADIUS = 1.25
NPCConfig.PATH_AGENT_HEIGHT = 5
NPCConfig.PATH_AGENT_CAN_JUMP = false
NPCConfig.PATH_AGENT_CAN_CLIMB = false
NPCConfig.PATH_WAYPOINT_SPACING = 4

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

-- [[ Boarding (GateService integration) ]] --
NPCConfig.BOARD_DWELL = 2 -- seconds an NPC lingers at the Depart Node, once boarding is open, before despawning ("boarding the plane")
NPCConfig.RESPAWN_DELAY_MIN = 5 -- seconds after a boarded NPC despawns before its replacement spawns, randomized in this range
NPCConfig.RESPAWN_DELAY_MAX = 10

-- [[ Assets ]] --
NPCConfig.RIG_TEMPLATE_PATH = { "Assets", "Rig" } -- ReplicatedStorage.Assets.Rig

return NPCConfig
