# Airport Security! — CLAUDE.md

Roblox game project, synced to Studio via Rojo from `sync/`. Legacy/reference-only code lives in `legacy/` — read it for architecture ideas when porting old systems, never copy it verbatim (it predates the current node-graph/record-based NPC system and often uses outdated APIs).

## Comments — read this first

**Do not write excessive comments.** Default to none. Code should read clearly from naming and structure alone. If a comment is truly necessary (a non-obvious constraint, a workaround for a specific engine quirk, a hard-won bug fix), keep it to one tight line — never multi-paragraph rationale blocks, never narration of what the next line does, never comments referencing "the user asked for X" or session history.

The one exception: structural section-header comments matching this codebase's template (see below) are always fine and expected — they're dividers, not explanations.

## Framework conventions

This project uses a custom Service/Controller framework, not plain vanilla Roblox scripting:

- **Services** (`ServerScriptService/Services/*.luau`) — server-side. **Controllers** (`StarterPlayer/StarterPlayerScripts/Controllers/*.luau`) — client-side.
- Every module returns `Shared`, with private helpers on a separate `Local` table. Public API only through `Shared.*`; `Local.*` is never required/read cross-module.
- Lifecycle: `Shared.Init()` (register, don't yield), `Shared.Start()`, `Shared.Destroy()` (disconnect everything tracked).
- Standard section layout, always in this order — keep these headers even though everything else gets trimmed:
  ```
  --|| Services
  --|| References
  --|| Types
  --|| Variables
  --|| Constants
  --|| MAIN ||--
  --[[ Signals ]]--
  --[[ Startup ]]--
  --[[ Private Functions ]]--
  --[[ Public Functions ]]--
  ```
- Every `RBXScriptConnection` / `Network.Cleanup` gets stored and disconnected in `Destroy()`.
- `task.wait()`/`task.spawn()`/`task.defer()`/`task.delay()` — never bare `wait()`.
- Strict Luau types on public function signatures and non-trivial data shapes.

## Network module

`ReplicatedStorage/Modules/Network` — this project uses **NetworkLite** (no Blueprints, no Ser/Deser). Event/key arguments are plain string literals (e.g. `Network:BindEvent("Item", "RequestPickup", ...)`), not a `Network.Remote.*` constants table. Never use raw `RemoteEvent`/`RemoteFunction` — always go through `Network`. Store every `BindEvent`/`BindEventOnce`/`BindLocalEvent` cleanup handle and disconnect it in `Destroy()`.

## Key systems (orientation, not exhaustive)

- **NpcService** (`ServerScriptService/Services/NpcService/`) — crowd NPC AI. `NodeGraph.luau` is the node/zone graph (Transition/Conveyor/Pickup/Seat/Line nodes, LoS caching, EnRoute load-balancing). `Behaviors/` holds pluggable decision modules (`Linear`, `Wander`) run inside a parallel `Actor` (`ActorScript.server.luau`) — decisions come back async via a `BindableEvent`, never assume synchronous return. `init.luau` owns the per-NPC `record` state table, the Heartbeat tick loop, and movement (`Local.SetWalkTarget` sets `Humanoid.WalkToPoint` directly rather than calling `:MoveTo()`).
- **CharacterController** (`ReplicatedStorage/Modules/Shared/CharacterController.luau`) + **CharacterAnimations** (`ReplicatedStorage/Modules/Configs/CharacterAnimations.luau`) — shared Idle/Walk/Run/Jump/Fall/Climb/Sit pose state machine and contextual IdleAction1/2, used identically by both players (`CharacterService` destroys the default `Animate` script and drives this instead) and Crowd NPCs.
- **ItemService** — item pickup/equip/throw/bag system. Each item's own module under `ReplicatedStorage/Modules/Configs/ItemsConfig/` defines `properties`/`attributes`/`OnEquip`/`OnUnequip`. The Weld→Motor6D grip swap normally only happens via a real player's client-fired Network "Equip" event — NPCs go through `Local.SwapGripWeldToMotor` instead (server-side equivalent, since NPCs have no client to fire that event).
- **Observers** (`ReplicatedStorage/Modules/Libs/Observers`) — CollectionService-tag-reactive helper (`observeTag`, `observeDescendants`, `observeCharacter`) used throughout for applying setup logic to tagged/descendant instances, including ones added later.
- **PhysicsService collision groups** — registered centrally in `CharacterService.Shared.Init()`. Groups default to collidable unless explicitly set `false`.

## Workflow

- Test changes live in Studio before considering a task done when possible; state plainly when something can't be verified that way instead of claiming success.
- Only `git commit` when explicitly asked.
- Don't be precious about a just-implemented approach — this project iterates fast and pivots on live-test feedback often; revert/replace cleanly rather than layering workarounds on top of an approach that didn't pan out.
