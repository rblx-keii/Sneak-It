# NPC AI — Reactive Crowd + Decoys

> **2026-07-17: rebuilt again — `NpcService` (Service + Actor + Behavior modules), `Linear` behavior only.** After the OOP `Manager`/`BaseNPC` attempt was deleted for paper planning, the user returned with a concrete architecture modeled on a reference `NpcService` from one of their previous games: a plain `Local`/`Shared` service (no OOP classes) that injects a per-NPC `Actor` running a cloned template script, driven by a `RunService.Heartbeat`-fanned-out `"UpdateAI"` message, with `task.synchronize()` called immediately at the top of every handler. Swappable **Behavior modules** (name-dispatched, `NpcService/Behaviors/`) decide "what's my next node" — only `Linear` exists so far (no traits, walks the fixed backbone `Lobby → Concourse → Platform → Depart` straight through). See **"Current implementation (NpcService)"** below for the full design. The *original* functional implementation (traits, Decoys, Seat/Conveyor/Interaction/Stand nodes, Alert/Panic/contagion) documented further down is still an accurate **design record** for future Behavior modules, but its code lives only in `legacy/` (project root, not loaded by Rojo/Studio, no git history to fall back on otherwise) — none of it is live.

---

## Current implementation (`NpcService`)

`sync/ServerScriptService/Services/NpcService/` — a **folder** (Rojo's folder+`init.luau` convention collapses it into one ModuleScript, so `Loader.luau` still discovers it unchanged), structured to mirror the user's reference exactly: the Actor template script and the Behaviors dispatcher are literal children of the service.

```
NpcService/
  init.luau                 -- the Service: spawn/despawn, Heartbeat fan-out, public API
  NodeGraph.luau             -- stateless graph-reading/writing helpers (shared by ActorScript + every Behavior)
  ActorScript.server.luau    -- Actor template (Script, cloned per NPC)
  Behaviors/
    init.luau                 -- name-keyed dispatcher (mirrors NPCNodes/MapInteractables)
    Linear.luau                -- the only Behavior module so far
```

### Round lifecycle (`init.luau`)

Same shape as every other round-scoped service: `RoundService.OnStateChange` spawns on `"Starting"`, despawns on `"Ended"`/`"Intermission"`. Spawns `NPCConfig.MAX_NPCS` rigs at `<ActiveMap>.Spawns.NPC` (same convention as before), and a single `RunService.Heartbeat` connection (gated by `RoundService.GetState() == "InProgress"`) sends `actor:SendMessage("UpdateAI", { dt = dt })` to every active NPC's Actor each frame — this fan-out, not manual per-call thread-safety auditing, is where the "parallel" benefit comes from.

`Local.InjectActor` creates an `Actor` per NPC, adds a `NodesFolder` `ObjectValue` pointing at the round's resolved `Nodes` folder (**this is how the Actor reaches the graph** — `require`-ing `MapService` from inside an Actor gets an isolated copy with no active map set, since `_activeMap` is a plain module-level Lua variable, not derivable from the Instance tree), then clones `ActorScript.server.luau` into it.

Public API unchanged in shape from prior iterations: `Shared.FindNPCById`, `Shared.IsNPC`, `Shared.GetNPCKind` (always `"Crowd"` — no Decoys this slice). `ArrestService`/`StealService` soft-require `"NpcService"` (renamed from `"NPCAIService"`) the same lazy way as before.

### Node graph authoring convention

Zone-subfoldered, a departure from the old flat `Nodes` folder:

- `<ActiveMap>.Nodes.<Zone>` for each zone: `Lobby`, `Concourse`, `Platform`, `Cafe`, `Souvenir`, `Convenience`. Ordinary nodes are `BasePart`s directly inside their zone folder.
- **`Depart Node`** is the one exception — a single `BasePart` parented **directly under `Nodes`**, not inside any zone subfolder. Its implicit zone is `"Depart"`.
- **`Link`** `ObjectValue` (unchanged from before): points at the single deterministic next node. Absent = Auto-search fallback (nearest eligible node, LOS-checked, zone-filtered — see below).
- **Line Node = a folder**, not a single part: a `Folder` named `Line Node` inside a zone folder, containing one main slot + N sub-slot `BasePart`s — **each slot is its own physical queue spot**, `Link`-chained together like any other node sequence. Every slot tracks occupancy via `PeopleInLine`/`MaxCount` attributes (default `MaxCount = 1`). A slot also counts as taken if any live `Player`'s character is within `NPCConfig.LINE_SLOT_PLAYER_RADIUS` (7 studs) of it, so a mixed player/NPC queue works via proximity alone — no central registration needed (Actors can't share a Lua table, so this *has* to be attribute/proximity-driven).
- **Entry Node**: a separate staging `BasePart` (named `Entry Node`) that a Line Node group's **main slot only** references via an `Entry` `ObjectValue`. Before joining that line from outside the group, an NPC detours to the Entry Node first, then proceeds — a designated merge point rather than approaching from an arbitrary angle. Entry Nodes are excluded from Auto-search's general candidate pool (`NodeGraph.IsEntryNode`) since they're only ever reached via this deliberate detour (`NodeGraph.ResolveEntryRedirect`). The Entry Node's own `Link` should point at the group's main slot, continuing the chain normally from there.
- **Zone-adjacency validity** (`NPCConfig.ZONE_ADJACENCY`): a fixed set of legal zone-to-zone pairs (`Lobby↔Concourse`, `Concourse↔Cafe/Souvenir/Convenience`, `Concourse↔Platform`, `Platform↔Depart`; same-zone is always implicitly valid). Auto-search is filtered by this — a behavior can only discover candidates in its current zone or a zone it's explicitly allowed to move toward next.

### `Linear` behavior (`Behaviors/Linear.luau`)

The only Behavior module so far — no traits, no side-trips. Tracks `NPCConfig.LINEAR_ZONE_SEQUENCE = {"Lobby", "Concourse", "Platform", "Depart"}` and only ever searches for next-node candidates in the current zone or the *next* zone in that fixed sequence — Cafe/Souvenir/Convenience are legal `ZONE_ADJACENCY` pairs but Linear never targets them (that's reserved for future trait-driven behaviors). Resolution priority: `Link` wins unconditionally if present; otherwise `NodeGraph.FindNearestNode` (zone-filtered, Entry-Node-excluded, backtrack-guarded the same way as before — a candidate whose own `Link` points back to where the NPC just arrived via a deterministic hop is skipped). Reaching a Line Node slot attempts to claim it (`NodeGraph.TryClaimLineSlot`); if the slot is taken, `Linear` reports `"Queueing"` and does nothing further that tick — the next Heartbeat naturally retries. A genuine dead end (standing at `Depart Node` with nothing past it) reports `"Arrived"` — a placeholder terminal state, since boarding-cycle gating (`Workspace.BoardingOpen`) still isn't built.

### Depart Node — boarding & despawn (2026-07-21)

The Depart Node stopped being a permanent dead end once `GateService.luau` (`sync/ServerScriptService/Services/`, new this session) started driving the airplane arrival/boarding/departure cycle — see `todo.md`'s Done section for the full cycle writeup. Integration is entirely one-directional and attribute-based, matching the rest of this codebase's convention: `NpcService` only *reads* `Workspace:GetAttribute("BoardingOpen")`, it never requires `GateService` directly.

`Local.OnArrive` stamps `record.departArrivedAt` the moment an NPC reaches a node whose zone (`NodeGraph.GetZone`) is `"Depart"`, resetting it to `0` on every other arrival. The Heartbeat loop in `Shared.Init` then holds that NPC — no decision request, same shape as the existing Seat/Line-dwell gates — until `Workspace.BoardingOpen` is true *and* `NPCConfig.BOARD_DWELL` (3s) has passed since arrival, at which point it despawns the NPC via `task.defer(Local.CleanupNPC, record.model)` (deferred because `CleanupNPC` mutates `_activeNPCs`, which this exact loop is iterating over) — the NPC "boards the plane." `Linear.luau` itself is untouched: it still just reports `(nil, "Arrived")` for the Depart Node dead end, same as before; the boarding wait/despawn is centralized in `NpcService` rather than pushed into the Behavior module, since it's dead-end-terminal handling that would apply to any future Behavior reaching the same node (mirrors why Seat/Line dwell logic lives in `OnArrive`/the Heartbeat loop rather than in `Linear.luau`).

### Parallel Luau model

`task.synchronize()` is called immediately at the top of **every** handler in `ActorScript.server.luau` (both the `Humanoid.MoveToFinished` connection and the `BindToMessageParallel("UpdateAI", ...)` callback) — matching the user's reference exactly rather than manually auditing which specific Roblox APIs are parallel-safe. Everything after that point behaves like ordinary main-thread code. Per-NPC state that only this script needs (`currentNode`, `waypoints`, etc.) is kept as **plain closure locals**, not Attributes — the Actor's Luau VM lives for the NPC's whole lifetime, so these survive across ticks/messages the same way the reference script's animation-track cache does. Attributes are reserved for state other systems/threads need to read (line-slot occupancy, the debug-visible `AIState` attribute).

Movement itself (per-leg `PathfindingService:ComputeAsync` + waypoint stepping + direct-line raycast fallback + `STUCK_TIMEOUT` recompute) is the same logic ported from prior iterations, just relocated into `ActorScript`'s closure. A new target/path is only (re)computed when the NPC is idle, arrived, or stuck — **not** every Heartbeat tick, since recomputing `ComputeAsync` 30-60×/sec per NPC would be wasteful.

### Deliberately not built this slice

Traits (Primary/Modifier), Decoys, Seat/Conveyor/Interaction/Stand node behaviors, Alert/Panic/contagion, Line Impatience, side-shop detours (Cafe/Souvenir/Convenience) — all still design-recorded in the sections below and in `legacy/README.md`, to become additional `Behaviors/` modules (or extensions to `NodeGraph`) once the user's paper plan calls for them.

---

## Original design record (pre-`NpcService`, not currently live)

Documented 2026-07-16, extended 2026-07-17, code superseded 2026-07-17 (twice — see banner above). The section below describes `legacy/NPCAIService.luau`'s design in full: node graph discovery, movement, the state machine, contagion, Decoys, and a per-NPC trait system with parallel-Luau decision-making (via genuine `Actor`+`BindableEvent` message-passing, not the `task.synchronize()` model `NpcService` uses now). Kept as the implementation reference for whichever pieces return as new Behavior modules.

## Goal

A crowd of background NPCs to make rounds feel busier and more chaotic, inspired by "Airport Security Sucks!" and a reference YouTube video the user shared. NPCs are reactive rather than scripted-on-rails, have distinct personality traits that shape how they move through the airport, and a handful act as Decoys that behave like real Smugglers to keep TSA honest.

## Node graph

Authored per map template in `ServerStorage.Maps.<MapName>.Nodes` (the map's `Nodes` Folder). `NPCAIService` resolves this folder once per round (via `MapService.GetActiveMap()`) rather than a continuous tag scan — map templates only clone once per round, so nothing is cached across rounds.

Each node is a `BasePart` inside `Nodes`:

- **Name determines type**, matched the same way `MapInteractables` dispatches (`Name:gsub(" ", ""):lower()` against a handler table in `ReplicatedStorage/Modules/Configs/NPCNodes/`): `Node` (Basic), `Line Node`, `Seat Node`, `Conveyor Node`, `Interaction Node`, `Stand Node`.
- **Child `Attachment`** — every node has one; used as the precise position/orientation reference (queue-slot spacing direction, belt/seat alignment) instead of the raw part's `Position`.
- **Optional child `ObjectValue` named `Link`** — its `.Value` points to the single next node. Present = **Linked** (deterministic routing — required for Line/Seat/Conveyor so their ordering is deliberate). Absent/empty = **Auto** (runtime nearest-eligible-node-with-clear-line-of-sight fallback, biased by an optional `GoalWeight` attribute; mainly for open areas like the concourse). Auto-search also refuses to route into a node whose own `Link` would immediately send the NPC straight back the way it came (only relevant right after a deterministic Link hop — see `arrivedViaLink` in the movement section).
- **Optional `Location` attribute** (string) — a zone tag, e.g. `Lobby` / `Concourse` / `Platform` / `Cafe` / `Convenience` / `Souvenir`. Used by trait behaviors to search for a node in a specific zone (Caffeinated seeking a Cafe node, etc.) via `Local.FindNearestNodeOfType`.
- **`Occupied` attribute** (boolean) — mirrored automatically by `NPCAIService` on Seat/Stand/Interaction nodes whenever an NPC occupies one; not authored by hand, just useful for inspecting a map live in Studio. The actual source of truth stays in `Local.seatOccupancy`/`Local.nodeOccupancy`.
- **Conveyor nodes**: `Link` points at the paired exit node on the far side of the metal detector.
- **Seat nodes**: the part is (or its `Link` target is) an actual `Seat`/`VehicleSeat`; falls back to a stationary timed pause if not.
- **Interaction nodes**: cosmetic dwell point (Vending Machine / Inquiry Desk / Shelf / ATM) — no economy/system hookup. Single-occupant; pass-through if already occupied.
- **Stand nodes**: a designated standing spot, no `Sit` — same single-occupant/dwell/pass-through shape as Interaction, just standing instead.

No `Nodes` folder, or an empty one, is a soft failure — `NPCAIService` warns and spawns no NPCs that round rather than erroring.

## NPC spawn point

`<ActiveMap>.Spawns.NPC` — a single `BasePart` zone, matching `SpawnService`'s existing `<ActiveMap>.Spawns.<TEAM_NAME>` convention (`Local.GetSpawnZone`/`Local.GetRandomPositionInPart`). Falls back to a random known node position (warns) if `Spawns.NPC` doesn't exist yet.

## Movement

- **Basic ("Node")**: just a general waypoint along the path, not a precise mark — arrivals spread across a small radius (`NODE_SPREAD_RADIUS`) instead of every NPC funneling through the exact same point (`Local.GetMovementTargetPosition`). Line/Seat/Conveyor/Interaction/Stand nodes all keep their canonical position exactly since they need precision (queue spacing, seat alignment, belt start/end, dwell placement).
- Node-to-node legs route through `PathfindingService` (`Local.ComputePath`/`MoveToWaypoint`) — each leg computes a navmesh path and the NPC walks its waypoints, routing around corners/walls instead of beelining. Falls back to the old single-raycast straight-line-clipped-short movement (`Local.MoveDirect`) only if `ComputeAsync` can't find a route — fails soft, not hard. A leg that doesn't progress within `STUCK_TIMEOUT` recomputes the path (or force-arrives, for the direct-line fallback).
- **Backtrack prevention**: `record.arrivedViaLink` tracks whether the NPC's current node was reached via the previous node's deterministic `Link` (e.g. just exited a Line/Seat/Conveyor sequence). When true, Auto-mode search (`FindNearestAutoNode`) additionally excludes any candidate whose own `Link` points straight back at where the NPC came from — without this, Auto-search could route an NPC into a node that would force an immediate walk back next hop (Linked nodes are unconditional, so that candidate has no choice but to backtrack).
- Each NPC gets a randomized `WALK_SPEED_JITTER` offset on spawn so the crowd doesn't move in lockstep.

## Node behaviors

- **Line**: FIFO single-file queue. Each queued NPC's slot dynamically targets a point `SLOT_SPACING` studs behind whoever is directly ahead of it in the queue (`Local.GetLineSlotPosition`) — literally "walk behind the last person in line," not a fixed grid computed purely from the node position — recomputed whenever `AdvanceLine` reindexes (anyone joining/leaving). Front slot (index 1) always targets the node itself. The front NPC dwells `LINE_DWELL` seconds, then proceeds. Panic/despawn correctly compacts the queue.
- **Seat**: sits (`Seat:Sit`/`Humanoid.Sit`) for a random `SEAT_MIN_DURATION..SEAT_MAX_DURATION`, then stands and resumes. An already-occupied seat is a pass-through, not a wait.
- **Conveyor**: the NPC's held item is detached (`ItemService.ForceDropItem`, which re-tags it `Interactable`) and interpolated along the belt (`startPos → endPos` over `BELT_TRAVEL_TIME`) as a free-standing object — **stealable mid-transit** through the ordinary `ItemService.PickupItem` flow. The NPC walks normally to the paired exit node and reclaims the bag there via a two-sided handshake (`CompleteBeltArrival`/`TryReclaimBag`); if it was stolen mid-belt, reclaim silently no-ops. **Automated contraband detection**: the moment the bag is dropped onto the belt, `ItemService.GetContrabandItemCount(bag) > 0` is checked — a hit calls `Shared.ForcePanic(nodePosition, CONVEYOR_DETECT_RADIUS, CONVEYOR_DETECT_REQUIRE_LOS)` automatically, no TSA player needed. This is real detection, not cosmetic — it changes smuggling-loop balance (a Decoy or a Thief holding stolen contraband gets caught by the environment itself). The checkpoint itself never arrests/captures anyone — that authority stays with `ArrestService`.
- **Interaction / Stand**: dwell for a random duration (`INTERACTION_DWELL_MIN/MAX`, `STAND_DWELL_MIN/MAX`), mirroring `Occupied` onto the node attribute, then resume via `AdvanceOrWait`. Purely cosmetic — no economy/system hookup.

## Traits (Crowd-kind only — Decoys never roll one)

Every Crowd NPC gets exactly one **Primary** trait (mutually exclusive, governs the overall movement pattern) plus any number of independently-rolled **Modifier** traits (stack freely on top of whichever Primary is active).

**Primary** (`NPCConfig.PRIMARY_TRAIT_WEIGHTS`):
- **WalkIn** — seeks the nearest Line Node near spawn ("buys a ticket") before falling into the normal graph-traversal flow.
- **Hasty** — skips every optional detour (Rest/Wander, Cafe divert, Theft) and beelines toward the goal. Renamed from "QuickFeet."
- **Loiterer** — never actually commutes toward the boarding gate; perpetually picks a random nearby reachable node and wanders (`Local.LoiterStep`). Can incidentally sit/queue/dwell if it wanders into one of those nodes, but every arrival routes back to loitering.

**Modifiers** (`NPCConfig.MODIFIER_CHANCE`, each rolled independently):
- **Weary** — elevated chance to seek a seat instead of proceeding (`WEARY_REST_CHANCE` vs the baseline `REST_CHANCE`); also raises Line Impatience slightly (`IMPATIENCE_WEARY_BONUS`). Renamed from "QuickToTire."
- **Caffeinated** — periodically diverts toward a `Location == "Cafe"` node (cooldown + chance gated); once it leaves the Cafe zone (tracked in `Local.UpdateCaffeineTracking`), gets a one-time permanent `WalkSpeed` boost and a higher Alert-escalate chance (`CAFFEINE_ALERT_ESCALATE_CHANCE` overrides `ALERT_ESCALATE_CHANCE` via `record.stateData.alertEscalateChanceOverride`) for the rest of the round.
- **Thief** — periodically targets a nearby Crowd NPC holding an item (cooldown + chance gated), walks to them, and after `THIEF_APPROACH_DURATION` transfers the item (`ItemService.ForceDropItem` → `EquipNPCItem`) and calls `Shared.ForceAlert(victim)` — NPC-vs-NPC theft, entirely autonomous (no player skill-check state machine, unlike the player-vs-NPC `StealService` flow).

**Rest/Wander** is the shared default step most Primaries fall back to at each node arrival (everything except Loiterer, which never proceeds normally, and Hasty, which skips it entirely): roll a chance to seek a seat (retrying for `REST_SEARCH_TIMEOUT` before giving up), else a chance to locally wander (with a sub-chance to detour into a nearby Interaction node), else just proceed.

**Line Impatience** applies to every queued Crowd NPC (not just Walk-In): ticks an accumulating meter while waiting behind the front of the line (`IMPATIENCE_ROLL_INTERVAL`), and once it crosses `IMPATIENCE_THRESHOLD` the NPC gives up — resolving to either seek a seat or leave the airport outright (`Local.LeaveAirport`, which walks back to the spawn zone and despawns on arrival). Per-Primary multipliers (`IMPATIENCE_PRIMARY_MULTIPLIER`) make Walk-In impatient (its whole gimmick) and Hasty nearly immovable (persistent, rarely gives up on anything between it and the gate).

## Brain Actors (parallel Luau AI decisions)

Every Crowd NPC gets its own **Actor** (`record.brainActor`, named `Brain`, parented into the NPC model) running a cloned `NPCBrainScript` (`sync/ServerScriptService/NPCBrain/NPCBrainScript.server.luau`) — this is where the actual "which behavior category applies right now" decision is computed, in genuinely parallel Luau (one independent VM per NPC). Decoys don't get one — their divert behavior stays on the existing simple, deterministic-feeling script (`MaybeDivertDecoy`), intentionally not randomized through the parallel system.

**Why the split is where it is**: Roblox's parallel Luau isolates each Actor's Lua state (no shared upvalues/module tables across the boundary) and restricts almost all Instance mutation to the main/serial thread. So the Actor only ever computes a *category* of decision (`"Loiter" | "Theft" | "CafeDivert" | "Rest" | "Wander" | "Proceed"`) from a plain-data snapshot handed to it in the request — pure `math.random()` against numbers, no Instance reads/writes. The main thread (`NPCAIService`) resolves the *specific target* (which seat, which victim, which Cafe node — using `Local.graph`/`Local.records`, caches an Actor can't see) and performs all the actual mutation (`WalkTo`, `SetAttribute`, queue/occupancy bookkeeping). Line-queue positioning in particular was called out as needing to stay centralized, which it always has — Actors never touch `Local.lineQueues` or any other shared table.

**Protocol**:
1. `Local.AdvanceOrWait` — for a Crowd NPC with a Primary trait and a live `brainActor` — calls `Local.RequestTraitDecision(record, fromNode)` instead of resolving synchronously.
2. `RequestTraitDecision` snapshots cooldown/modifier state into a plain request table (consuming Thief/Caffeinated cooldowns at request time, whether or not the roll actually hits — same pacing as the original synchronous version), then `record.brainActor:SendMessage("Decide", request)`. An epoch counter (`record.stateData.decisionEpoch`, same token pattern as `EnterPanic`'s `panicEpoch`) guards against stale/duplicate responses; a `DECISION_TIMEOUT` fallback (`task.delay`) invalidates the epoch and proceeds normally if the Actor never responds.
3. `NPCBrainScript`, running inside the Actor via `actor:BindToMessageParallel("Decide", ...)`, computes the decision and reports back by firing `Local.decisionReportEvent` — a single shared `BindableEvent` (created once at module load), referenced by every Actor via a `ReportEvent` `ObjectValue` child set up in `Local.CreateBrainActor`. Firing a `BindableEvent` from parallel context is one of the sanctioned ways to safely cross back to the main/serial thread.
4. `Local.OnDecisionReported` (connected in `Shared.Init`) receives `(uid, requestId, action)`, re-validates the epoch and that the NPC is still `Commuting` (wasn't Alert/Panic-interrupted while awaiting), then dispatches to the same execution functions the system already had (`LoiterStep`, `FindTheftVictim`+`StartTheft`, `FindNearestNodeOfType`+`WalkTo`, `TryRest`, `LocalWanderStep`, or falls through to `ProceedNormally`).

`Local.ProceedNormally` is the renamed former body of `AdvanceOrWait` (Decoy divert branch + `ResolveNextNode`/boarding-gate logic) — it's what both the timeout fallback and every non-trait-governed NPC (Decoys, and any Crowd NPC whose Actor failed to create) call directly.

## State machine

States live on `record.state` (mirrored to a debuggable `AIState` Instance attribute). `Local.SetState` is the single place state changes; `Local.AdvanceOrWait` is the single "proceed toward the goal" call every node handler and calm-down path funnels through (branching into the Actor request for trait-governed Crowd NPCs, or straight to `ProceedNormally` otherwise).

- **Commuting** — default. Follows the node graph toward the goal: for a regular crowd NPC that's boarding the plane (Zone D), modulated by traits as described above. Decoys use the same state but periodically divert toward the nearest `DepositZone`-tagged part instead, to visually mimic a Smuggler — purely cosmetic bait, since `DepositService` is entirely `Player`-keyed and a Decoy can never actually trigger/complete a deposit.
- **Queueing** / **Seated** — see node behaviors above.
- **Wandering** — reached the boarding-gate area (a graph dead end — no Link, no eligible Auto node) while `Workspace:GetAttribute("BoardingOpen")` is `false`. Idle-wanders near the gate node until it flips `true` (or is unset — **defaults to open**). See "Integration points" below. (Distinct from a Loiterer's perpetual local wander, which never reaches this dead-end check at all — the trait pre-empts it every time.)
- **Alert** — entered via `Shared.ForceAlert(npc)` (the `StealService`/Thief-modifier contract). Pulls the NPC out of any Queue/Seat/dwell, pauses `ALERT_LOOK_DURATION`, then with `ALERT_ESCALATE_CHANCE` (or a Caffeinated NPC's overridden chance) escalates to Panicking, else calms back to Commuting.
- **Panicking** — entered via escalation, `Shared.ForcePanic(position, radius, requireLineOfSight?)`, or witnessing a ragdoll. Erratic off-path movement for `PANIC_DURATION` (token/epoch counter). On entry, propagates to other NPCs within `PANIC_RADIUS` **and** clear line-of-sight (`CONTAGION_CHANCE` roll each).
- **DecoyJailed** — internal, not part of the reactive vocabulary. See Decoys below.

## Contagion / violence-witness

`RagdollService.luau` has an additive `Shared.OnRagdolled` signal (fires for both `Player` and NPC `Model` targets, unlike the pre-existing `OnPlayerRagdolled` which only fires for real players). `NPCAIService` connects to it and calls `Shared.ForcePanic(ragdollPosition, PANIC_RADIUS, false)` — covering player-on-NPC, NPC-on-NPC, and player-on-player ragdolls uniformly.

## Decoys

1–3 per round (`MIN_DECOYS`/`MAX_DECOYS`), out of the 30-NPC cap. Spawned holding a contraband item directly (`DECOY_BAIT_ITEM`, currently `"Passport"`) rather than a bag, so they read `HasContraband` to a TSA scan without needing the bag-steal mechanic (that's for crowd NPCs).

Catch mechanic: arresting a Decoy is **no stat change** — no TSA reward, no strike. `ArrestService.Shared.AttemptArrestNPC` (dispatched when the client sends `{ npcId }` instead of `{ targetUserId }`) classifies the target via `NPCAIService.GetNPCKind` (note: `require(NPCAIService)` returns the `Shared` table directly — call `npcAIService.GetNPCKind(...)`, not `npcAIService.Shared.GetNPCKind(...)`; a `.Shared.` indirection bug here silently broke NPC arrests entirely until fixed 2026-07-17, see `todo.md`): a **Decoy** calls `Shared.CaptureDecoy`, a regular **crowd** NPC calls the existing `Shared.RegisterFalseArrest` (a strike, per Project.md's 3-strike system).

`Shared.CaptureDecoy` teleports the Decoy to the `"Jail"`-tagged model for `DECOY_JAIL_DURATION`, then **destroys it and spawns a fresh replacement** (fresh trait roll included) rather than releasing it back into the crowd.

## Integration points for future work

- **Gate Lockdown** (`todo.md` Open item): call `NPCAIService.ForcePanic(position, radius, requireLineOfSight?)` — soft-required the lazy way `StealService`/`ArrestService` reach `NPCAIService` (`script.Parent:FindFirstChild("NPCAIService")` + `pcall(require, ...)`, then call directly on the returned module — **no `.Shared.`**, see the Decoys section above for why that matters).
- **Airplane/boarding cycle** — superseded 2026-07-21: this described the pre-`NpcService` legacy design (`GetAttributeChangedSignal`-driven, defaults to open when unset). The live cycle now ships as `GateService.luau`, and the current `NpcService` integration (Heartbeat-polled, defaults to *closed* when unset, despawn-on-board rather than idle-`Wandering`) is documented under "Depart Node — boarding & despawn" above.

## Deliberately deferred

- **Real trait variety for Decoy churn / crowd appearance** — the user separately wants a future randomizer that gives Smugglers/Decoys a player's-friends'-Humanoid-appearance look (with a userId-cache so friend lists aren't re-fetched constantly). Not built.
- **Decoys getting a brain Actor** — scope was intentionally limited to Crowd NPCs; Decoy bait behavior stays scripted/deterministic-feeling.

## Not yet verified

None of the trait/Actor/new-node-type work in this update has been playtested in Studio yet. In particular: the `NPCBrainScript` Actor messaging round-trip (`SendMessage`/`BindToMessageParallel`/`BindableEvent` fan-in) is new to this codebase — no prior Actor usage existed anywhere in the project before this — so it's the highest-risk untested piece. `PathfindingService` still needs actual collidable geometry between nodes to route around; a leg with no walkable path silently falls back to straight-line movement rather than erroring, so a badly-routed NPC is a level-geometry issue, not a code bug.
