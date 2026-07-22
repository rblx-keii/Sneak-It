# Legacy NPC AI (pre-OOP-rewrite)

Moved aside 2026-07-17 when the NPC AI system was rewritten as OOP (`Manager`/`BaseNPC` classes under
`sync/ReplicatedStorage/Modules/Shared/Classes/NPC/`). This folder is **outside** `sync/`, so nothing in
it is loaded by Rojo/Studio — it's pure reference material, not live code.

This was a fully-built, self-verified-but-never-playtested implementation covering far more than the new
system's first slice (movement + Line Node queueing + backtrack-prevented pathing only). Everything below
is still readable here, and `mds/NPC-AI.md` still documents the *design intent* in prose — only the code
was reset, not the plan. Use this as a porting reference when a deferred feature comes back into scope.

## Where each deferred feature's logic lives (in `NPCAIService.luau`, this folder)

- **Traits (Primary/Modifier system)** — `Local.RollPrimaryTrait`/`Local.RollModifiers` (~910–939),
  `Local.BeginCommuting` (~948–963), `Local.TickImpatience`/`Local.GiveUpOnLine` (Line Impatience,
  ~1069–1131), `Local.LoiterStep` (Loiterer, ~1211–1236), `Local.UpdateCaffeineTracking` (Caffeinated,
  ~1244–1260), `Local.FindTheftVictim`/`Local.StartTheft`/`Local.ResolveTheft` (Thief, ~1264–1338),
  `Local.TryRest`/`Local.LocalWanderStep` (Rest/Wander default, ~1140–1201). Tuning constants in
  `NPCConfig.luau`: `PRIMARY_TRAIT_WEIGHTS`, `MODIFIER_CHANCE`, `IMPATIENCE_*`, `REST_CHANCE`/
  `WEARY_REST_CHANCE`/`WANDER_CHANCE`/`WANDER_INTERACT_CHANCE`, `CAFFEINE_*`, `THIEF_*`.
- **Brain Actors (parallel Luau decisions)** — `Local.CreateBrainActor`/`Local.GetBrainScriptTemplate`
  (~423–459), `Local.RequestTraitDecision`/`Local.OnDecisionReported` (~965–1057), and the sibling
  `NPCBrainScript.server.luau` (this folder) — the isolated-Actor decision script itself.
- **Decoys (jail-and-churn capture)** — `Shared.CaptureDecoy`/`Local.ChurnDecoy` (~1904–1997),
  `Local.MaybeDivertDecoy`/`Local.FindNearestDepositZoneNode` (~1850–1883), `Local.GetJailModel`/
  `Local.GetJailStandCFrame` (~1885–1900). Tuning: `NPCConfig.DECOY_*`, `DECOY_BAIT_ITEM`.
- **Seat Node** — `Local.OccupySeat`/`Local.ReleaseSeat`/`Local.StandUpFromSeat`/`Local.FindSeatInstance`
  (~1600–1657). Handler: `NPCNodes/SeatNode.luau` (this folder).
- **Conveyor Node (belt-transit bag physics + automated contraband detection)** —
  `Local.StartConveyorTransit`/`Local.RunBeltTransit`/`Local.CompleteBeltArrival`/`Local.TryReclaimBag`
  (~1696–1843). Handler: `NPCNodes/ConveyorNode.luau`.
- **Interaction / Stand Nodes (cosmetic dwell points)** — `Local.DwellAtNode`/`Local.InteractAtNode`/
  `Local.StandAtNode`/`Local.ReleaseDwell` (~1659–1694). Handlers: `NPCNodes/InteractionNode.luau`,
  `NPCNodes/StandNode.luau`.
- **Alert / Panic / Contagion** — `Local.EnterAlert`/`Local.EnterPanic`/`Local.WanderErratically`/
  `Local.PropagateContagion` (~1382–1471), plus the `RagdollService.OnRagdolled` → `Shared.ForcePanic`
  wiring in `Shared.Init` and the `Shared.ForceAlert`/`Shared.ForcePanic` public hooks (~1917–1939) that
  `StealService`/the future Gate Lockdown service call.
- **Wandering (boarding-gate idle, `BoardingOpen`-gated)** — `Local.EnterWandering`/`Local.WanderStep`/
  `Local.OnBoardingOpenChanged`/`Local.IsBoardingOpen` (~1341–1380).
- **Held-item/bag equipping (player-vs-NPC stealing via `StealService`)** — `Local.EquipStarterItem`
  (~602–610). Without this, crowd NPCs have no `HeldItem` attribute, so `StealService.StartSteal` just
  returns `false` (no error) — inert, not broken.

## Full file index

- `NPCAIService.luau` — the ~2000-line functional service (node graph, movement, full state machine,
  traits, Decoys, all node types).
- `NPCConfig.luau` — full tuning config (all trait/Decoy/node knobs preserved, including ones the trimmed
  live `NPCConfig` dropped).
- `NPCBrainScript.server.luau` — the per-NPC parallel-Luau Actor decision script.
- `NPCNodes/` — the 6 node-type handler modules + `init.luau` dispatcher (`Node`, `LineNode`, `SeatNode`,
  `ConveyorNode`, `InteractionNode`, `StandNode`).
