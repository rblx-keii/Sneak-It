# Summary: Roblox NPC AI — Server-Side Decisions + Client-Side Replication/Visualization
Date: 2026-07-18 | Ideas: 19 | Forks: 2

## Key Themes
- Server says WHAT (state/attributes), client infers HOW (animation/movement polish) — explored in the abstract, then found entirely absent from the live NpcService, which is raw default-replication server authority
- Personality/trait data (legacy Primary/Modifier system) is nearly free to repurpose as client-side cosmetic variety, since Roblox Attributes already auto-replicate
- Movement/position trust (anti-exploit reconciliation) and network/physics ownership are two faces of the same question: who does Roblox think actually controls an NPC's body
- A real live bug (seated-server / wandering-client desync in NpcService + StealService) stress-tested every abstract idea and produced one strong, code-grounded (unconfirmed) hypothesis

## All Ideas
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

## Forks Explored
- Personality/variety systems for puppets: repurposing legacy trait/modifier data as client-side cosmetic flavor; also where the user's own ghost-rig/anti-exploit movement idea surfaced
- Network Ownership / Physics Authority: who actually controls NPC physics, resolving into the leading hypothesis for the real live bug

Full session: brainstorm-untitled-20260718-2314.md
