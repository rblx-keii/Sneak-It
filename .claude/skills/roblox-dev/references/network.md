# Network Module Reference
**author: Keii | v1.0**

A multiplexed, blueprint-driven network layer. All traffic travels over two shared remotes (`_R` reliable, `_U` unreliable). Packets are batched per-frame and identified by a compact u8 event ID synced from server to client on join.

---

## Architecture

| Component | Detail |
|---|---|
| `_R` | `RemoteEvent` — reliable ordered traffic |
| `_U` | `UnreliableRemoteEvent` — unreliable traffic |
| `_Invoke` | `RemoteFunction` — invoke calls, not batched |
| `_Sync` | `RemoteEvent` — ID table, server → client on join |
| Wire format | Flat array `{ id1, payload1, id2, payload2, … }`, flushed once per Heartbeat (server) / RenderStepped (client) |
| Event IDs | u8, server-assigned. Max **255** unique event:key pairs |
| Blueprints | `ModuleScripts` under `Network/Blueprints/<EventName>.luau` |
| `__main` | Implicit key for single-key events — callers omit the key argument entirely |

---

## Blueprint Schema

Every Blueprint module must return a table:

```luau
type Blueprint = {
    Schema:     any?,                              -- Sera schema for serdes
    Validator:  ((data: any) -> boolean)?,         -- optional extra validation
    Unreliable: boolean?,                          -- route over _U if true
    Delta:      boolean?,                          -- use Sera delta serialization
    RateLimit:  { maxCalls: number, window: number }?,
}
```

**Single-key blueprint** (implicit `__main`):
```luau
-- Blueprints/Bomb.luau
return {
    Schema     = Sera.Struct({ x = Sera.U8, y = Sera.U8 }),
    Unreliable = false,
    RateLimit  = { maxCalls = 10, window = 1 },
}
```

**Multi-key blueprint**:
```luau
-- Blueprints/Grid.luau
return {
    SendGridData = {
        Schema = Sera.Struct({ ... }),
    },
    UpdateGridTile = {
        Schema     = Sera.Struct({ ... }),
        Unreliable = true,
    },
    RequestGridData = {
        RateLimit = { maxCalls = 3, window = 10 },
    },
}
```

---

## Quick Reference

| Goal | Method |
|---|---|
| Server → all clients | `FireAll` |
| Server → all except blacklist | `FireAllExcept` |
| Server → specific client(s) | `FireClient` |
| Server → client, expect response | `InvokeClient` (returns Promise) |
| Client → server | `FireServer` |
| Client → server, expect response | `InvokeServer` (returns Promise) |
| Same-env only (no remote) | `FireLocal` / `BindLocalEvent` |
| Listen for incoming fire | `BindEvent` |
| Handle incoming invoke | `BindFunction` |
| Register send-only key | `RegisterEvent` (or fires auto-register) |
| Read blueprint config at runtime | `GetBlueprint` |

---

## Shared API (server + client)

### `Network.Remote`
`{ [string]: string }` — populated automatically on bind/register. Always use this as the event argument for typo safety and autocomplete.

```luau
Network:FireServer(Network.Remote.Bomb, data)
Network:FireAll(Network.Remote.Grid, "UpdateGridTile", data)
```

### `Network:BindEvent(event, callback) → Cleanup`
### `Network:BindEvent(event, key, callback) → Cleanup`
Registers a cross-environment listener. Requires a Blueprint for the event:key pair.
- Server callback: `(player: Player, data: any) -> ()`
- Client callback: `(data: any) -> ()`

```luau
-- multi-key
Network:BindEvent("Grid", "RequestGridData", function(player, data)
    Network:FireClient("Grid", "SendGridData", player, buildPayload())
end)

-- single-key (__main shorthand)
Network:BindEvent("Bomb", function(player, data)
    BombService.Place(player, data.x, data.y)
end)
```

### `Network:RegisterEvent(event, key?)`
Registers a send-only key so it receives an ID and is synced to clients, without attaching a listener. Use for keys the server only fires and never listens to. Auto-registration on first fire also handles this transparently — explicit calls only needed when you want the ID allocated before the first fire.

### `Network:BindFunction(event, callback) → Cleanup`
### `Network:BindFunction(event, key, callback) → Cleanup`
Registers a cross-environment invoke handler. Callback **must return a value**.
- Server callback: `(player: Player, data: any) -> any`
- Client callback: `(data: any) -> any`

```luau
Network:BindFunction("Shop", "GetInventory", function(player, _data)
    return InventoryService.GetFor(player)
end)
```

### `Network:BindLocalEvent(event, callback) → Cleanup`
### `Network:BindLocalEvent(event, key, callback) → Cleanup`
In-process only. No remote, no serialization. Ideal for client-side prediction or intra-service communication.

### `Network:FireLocal(event, data)`
### `Network:FireLocal(event, key, data)`
Fires an in-process local event. Only `BindLocalEvent` listeners on the same environment receive it.

### `Network:GetBlueprint(event, key?) → Blueprint?`
Returns the resolved Blueprint for an event:key pair, or `nil` if none exists.

---

## Server API

### `Network:FireAll(event, data)`
### `Network:FireAll(event, key, data)`
Enqueues a fire to every connected client. Flushed end of frame. Respects `Blueprint.Unreliable`.

### `Network:FireAllExcept(event, blacklist, data)`
### `Network:FireAllExcept(event, blacklist, key, data)`
Same as `FireAll` but skips players. `blacklist` accepts a single `Player` or `{ Player }` array.

### `Network:FireClient(event, client, data)`
### `Network:FireClient(event, key, client, data)`
Enqueues a fire to one or more specific clients. Accepts a single `Player` or `{ Player }` array.

```luau
Network:FireClient("Grid", "SendGridData", player, payload)
Network:FireClient("Notification", { p1, p2 }, message)
```

### `Network:InvokeClient(event, client, data) → Promise`
### `Network:InvokeClient(event, key, client, data) → Promise`
Invokes a single client via RemoteFunction. **Not batched.** Returns a Promise. Use sparingly — can hang if client is unresponsive.

```luau
Network:InvokeClient("Dialog", player, prompt)
    :andThen(function(choice) handleChoice(player, choice) end)
    :catch(function(err) warn("InvokeClient failed:", err) end)
```

---

## Client API

### `Network:FireServer(event, data)`
### `Network:FireServer(event, key, data)`
Enqueues a fire to the server. Flushed end of frame. If called before the sync payload is received, the fire is held in a pending queue and dispatched automatically after sync.

### `Network:InvokeServer(event, data) → Promise`
### `Network:InvokeServer(event, key, data) → Promise`
Invokes the server via RemoteFunction. **Not batched.** Rejects immediately if the event ID is not yet synced.

```luau
Network:InvokeServer("Shop", "Purchase", { itemId = "shield_class" })
    :andThen(function(result) applyPurchase(result) end)
    :catch(function(err) warn("Purchase failed:", err) end)
```

---

## Rate Limiting

Configured per Blueprint key via `RateLimit = { maxCalls, window }`. Uses a per-player token bucket. Violations are silently dropped on the server (logged when `DEBUG_TOGGLE = true`).

- Only applies to **client → server** fires. Server → client is never rate-limited.

```luau
RateLimit = { maxCalls = 10, window = 1 }  -- max 10 fires per second
```

---

## Delta Serialization

Set `Delta = true` in a Blueprint to use `Sera.DeltaSerialize`. Only changed fields are included in the payload — useful for frequent updates to large structs (e.g. player state, tile maps).

```luau
UpdatePlayer = {
    Schema     = Sera.Struct({ health = Sera.U8, shield = Sera.Bool }),
    Delta      = true,
    Unreliable = true,
}
```

---

## Cleanup

`BindEvent`, `BindFunction`, and `BindLocalEvent` all return:
```luau
type Cleanup = { Disconnect: () -> () }
```
Always call `:Disconnect()` when the listener is no longer needed. Leaking connections on player removal is a common bug.

```luau
local conn = Network:BindEvent("Bomb", handler)
-- later:
conn:Disconnect()
```

---

## Configuration Flags

Set at the top of `init.luau`:

| Flag | Default | Purpose |
|---|---|---|
| `DEBUG_TOGGLE` | `true` | Log bind/register/sync events. Set `false` in prod. |
| `VERBOSE_FLUSH` | `false` | Log every frame flush with byte estimates. Only for bandwidth diagnosis — expensive. |

---

## Limits

| Constraint | Value |
|---|---|
| Max unique event:key pairs | 255 (u8 ID space) |
| Blueprint location | `Network/Blueprints/<EventName>.luau` |
| Invoke calls | Not batched — use sparingly |
| Client pre-sync fires | Auto-queued and flushed after sync |
