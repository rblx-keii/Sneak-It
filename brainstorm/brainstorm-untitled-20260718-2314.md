# Brainstorm: Roblox NPC AI — Server-Side Decisions + Client-Side Replication/Visualization
Date: 2026-07-18 23:14
Technique(s) used: Free Association, SCAMPER, Analogy Hunt

## [MAIN] Roblox NPC AI: Server Side Calculation and Decisions + Client Side Replication and Visualization

### Constraints established
- Scope: Airport Security! specific (queues, checkpoints, passenger NPCs)
- Feel: "puppet is good enough" — server does real thinking, client shows convincing puppet, no need for client-perceived intelligence
- Scale: 20-30 NPCs on screen at once (medium crowd, not full crowd-sim)

### Ideas

---
## [FORK 1] Personality/variety systems for puppets (grounded in legacy/NPCAIService.luau)
Parent: MAIN
- Idea: client reads Trait/Modifiers attributes once at spawn to pick an animation/voice-bark bucket for NPC's lifetime
- Idea: AIState attribute is already the WHAT-vocabulary; client just needs a state->animation table, no new replication needed
- Idea: client-side parallel "mirror brain" (Actor) for cosmetic micro-behavior (idle fidgets, glances), off main thread
- Idea: WALK_SPEED_JITTER pattern extends to animation speed / bark pitch / idle timing
- Idea: combine Primary+Modifier into a client "flavor key" driving posture/expression (Hasty leans forward, Weary slouches)
- Idea: multiple stacked Modifiers = layered cosmetic quirks (jittery+droopy alternating)
- Idea: Decoys get a deliberate visual "off" tell client-side, without server ever hinting suspicion
- Provocative Q: what if personality could visibly drift over a round instead of being fixed at spawn?

- User pivoted to: server/client position-checking + anti-exploit for NPC movement (own "ghost rig" idea: server computes authoritative path+timing with a temp/invisible rig, client also moves + self-reports position, server accepts within threshold or corrects)
- Idea: ghost doesn't need a physical body — just a data curve (waypoints + expected-arrival-timestamps) computed once via PathfindingService; "expected position at time T" = interpolation, no second simulated body needed
- Idea: stagger/round-robin position validation across the 20-30 NPCs instead of checking every NPC every frame
- Idea: correction snap vs smooth-lerp scaled by whether a player is actually looking at that NPC on-screen
- Idea: trust tiers — tight tolerance near checkpoints/scoring-critical moments, loose tolerance for idle wanderers
- SCAMPER Eliminate: server only validates waypoint-arrival events (coarse, cheap) instead of continuous position polling
- SCAMPER Reverse: client self-reports only when it detects its own drift from the server-issued path, rather than server polling everyone constantly
- Analogy: this is the same predict-then-reconcile pattern already standard for *player* movement anti-cheat on Roblox, just pointed at NPCs; also racing-game ghost-car rubber-banding, fighting-game rollback netcode
- Real precedent found via web search: Roblox anti-exploit patterns (token-bucket rate limiting, server never trusts client-supplied positions), Roblox Creator Hub "server authority techniques" doc, DevForum threads on reconciling player movement — confirms predict+reconcile is the established analogous pattern
- Open provocative Q: legacy system already had 100% server-side movement (PathfindingService + MoveTo run server-side, client only sees replicated result) — what's actually motivating giving the client real authority here (smoothness? server cost at scale? something else)?

### Real bug found in live code (sync/ServerScriptService/Services/NpcService/init.luau + StealService.luau)
User report: NPC stays seated server-side but client sees it wandering the map — risk of invalid steal targeting.
Grounding facts from the live code:
- NpcService is 100% server-authoritative movement (PathfindingService + Humanoid:MoveTo on main thread), no explicit client-side visualization layer exists yet
- Only one SetNetworkOwner(nil) call exists, at spawn time, and only for parts caught Anchored — no persistent enforcement of server ownership afterward
- Seating uses real Seat:Sit(humanoid) (standard Roblox weld), relies on default replication
- StealService.GetDistance reads npcModel.HumanoidRootPart.Position server-side (server truth) for its distance checks
- Hypotheses raised (not diagnosed/confirmed): (1) Roblox automatic network ownership handed the NPC's HRP to a nearby player's client, whose local physics diverged; (2) leftover client-side interpolation/tween animating toward a stale moveTargetPos after server already committed to Seat; (3) stray Heartbeat-loop artifact still calling MoveTo-equivalent client-side after seating
- Framed as the live smoking-gun example of the whole "server says WHAT, client shouldn't invent its own HOW" thread — currently there's no explicit split at all, just raw default Roblox replication

---
## [FORK 2] Network Ownership / Physics Authority
Parent: FORK 1
- Idea: recurring sweep (Heartbeat/interval) that re-asserts SetNetworkOwner(nil) on any NPC part that drifted to auto-assignment, closing the "only-once-at-spawn" gap
- Idea: make ownership a deliberate design lever — decorative/never-interactable NPCs allowed to be client-auto-owned for performance, any NPC carrying HeldItem/bag force-pinned server-owned at spawn
- Idea: expose current physics owner as an inspectable attribute/debug marker so drift is visible in Studio, not just discovered via gameplay report
- Idea: explicit ownership re-pin at the exact moment Seat:Sit() is called, since welding/hierarchy changes are a natural moment for implicit reassignment to sneak in
- Analogy: server-pinned physics for scoring-critical objects (the ball/puck) in competitive games even at a smoothness cost; air-traffic-control ground-radar as authoritative truth over self-reported position
- Yellow Hat: an ownership-policy fix is a single systemic fix point — sitting, walking, wandering all inherit correctness for free once physics authority itself is nailed down
- Provocative Q: should all 20-30 NPCs be permanently server-owned given "puppet is good enough" (client never needed real authority), or is there a case for letting purely decorative NPCs stay client-owned?

### Diagnosis narrowing (still hypothesis, not confirmed — brainstorm mode, no fix applied)
- Confirmed via grep: sync/StarterPlayer has zero custom NPC-related client scripts — everything there is default Roblox PlayerModule (camera/click-to-move/VR) or player-character controllers (Arrest/Steal/Item). Rules out a custom client visualization bug entirely.
- Leading hypothesis: Humanoid:MoveTo() doesn't just set a target — it hands the actual walk *simulation* (velocity, animation state) to whichever machine holds network ownership of that Humanoid's parts. NpcService only calls SetNetworkOwner(nil) once, at spawn, for parts caught Anchored — never re-asserted afterward. If Roblox's automatic ownership system later hands the NPC to a nearby player's client, that client's own engine drives the walk locally; if a residual WalkToPoint wasn't explicitly cleared when the server transitioned the NPC to Seated, that client could keep visually walking it while server truth (and StealService's distance check) correctly sees it seated and stationary.
- Downgraded hypotheses: stale debug waypoint markers mistaken for the NPC itself (separate small Parts, unlikely to read as "walking"); pure StreamingEnabled culling artifact (would look like teleport/pop-in, not coherent walking).

## Final Summary

### Key Themes
- Server says WHAT (state/attributes), client infers HOW (animation/movement polish) — a replication philosophy explored in the abstract, then found to be entirely *absent* from the live NpcService, which is raw default-replication server authority
- Personality/trait data already exists server-side (or existed in legacy/) and is nearly free to repurpose as client-side cosmetic variety, since Attributes already auto-replicate
- Movement/position trust (anti-exploit reconciliation) and network/physics ownership turned out to be two faces of the same underlying question: who does Roblox think is actually in charge of an NPC's body
- A real live bug (seated-server / wandering-client desync in NpcService + StealService) became a concrete stress-test for every abstract idea generated, ending in a strong, code-grounded (but unconfirmed) hypothesis

### Ideas Generated (19)
1. Client reads Trait/Modifiers attributes once at spawn to pick an animation/voice-bark bucket for the NPC's lifetime
2. AIState attribute is already the WHAT-vocabulary — client just needs a state→animation lookup table
3. Client-side parallel "mirror brain" Actor for cosmetic micro-behavior (idle fidgets, glances), off the main thread
4. Extend the WALK_SPEED_JITTER pattern to animation speed / bark pitch / idle timing
5. Combine Primary+Modifier into a client "flavor key" driving posture/expression (Hasty leans forward, Weary slouches)
6. Layered cosmetic quirks from stacked Modifiers (jittery+droopy alternating)
7. Decoys get a deliberate visual "off" tell client-side, without the server ever hinting suspicion
8. Personality could visibly drift over a round instead of being fixed at spawn
9. Ghost-rig position validation as a lightweight data curve (waypoints + expected-arrival-timestamps), not a physically simulated body
10. Stagger/round-robin position validation across the 20-30 NPCs instead of checking everyone every frame
11. Correction snap-vs-smooth-lerp scaled by whether a player is actually looking at that NPC
12. Trust tiers — tight tolerance near checkpoints/scoring moments, loose tolerance for idle wanderers
13. Server validates only waypoint-arrival events (coarse, cheap) instead of continuous position polling
14. Client self-reports only when it detects its own drift, rather than server polling everyone constantly
15. Recurring sweep to re-assert SetNetworkOwner(nil) on any part that drifted to auto-assignment
16. Network ownership as a deliberate design lever — decorative NPCs client-owned, bag-carrying/interactable NPCs force-pinned server-owned
17. Expose the current physics owner as an inspectable debug attribute/marker
18. Explicit ownership re-pin at the exact moment Seat:Sit() is called
19. Leading bug hypothesis: Humanoid:MoveTo() hands actual walk simulation to whoever holds network ownership; since NpcService never re-asserts server ownership after spawn, an auto-reassigned client could keep locally simulating a stale WalkToPoint after the server has already moved the NPC to Seated

### Forks Explored
- FORK 1 — Personality/variety systems for puppets: repurposing legacy trait/modifier data as client-side cosmetic flavor; also where the user's own ghost-rig/anti-exploit movement idea surfaced
- FORK 2 — Network Ownership / Physics Authority: who actually controls NPC physics, and how that resolved into the leading hypothesis for the real live bug
