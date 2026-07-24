# NetworkLite Reference
**author: Keii | v2.0**

A multiplexed, lightweight network layer. All traffic travels over two shared remotes (`_R` reliable, `_U` unreliable). Packets are batched per-frame and identified by a compact u16 event ID synced from server to client on join.

**Key difference from Network (Ser/Deser):** Raw Luau data (tables, strings, numbers) is passed directly through remotes. No serialization, no type checking, no Blueprints required.

---

## Architecture

| Component | Detail |
|---|---|
| `_R` | `RemoteEvent` — reliable ordered traffic |
| `_U` | `UnreliableRemoteEvent` — unreliable traffic |
| `_Invoke` | `RemoteFunction` — invoke calls, not batched |
| `_Sync` | `RemoteEvent` — ID table, server → client on join |
| Wire format | Flat array `{ id1, payload1, id2, payload2, … }`, flushed once per Heartbeat (server) / RenderStepped (client) |
| Event IDs | u16, server-assigned. Max **65,535** unique event:key pairs |
| `__main` | Implicit key for single-key events — callers omit the key argument entirely |
| Adaptive arg resolution | If the second argument is a string, it is treated as the key; otherwise it is treated as data and `"__main"` is used |

> No Blueprints. No Sera schemas. No Delta or RateLimit config. Raw Luau data only.

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
| Listen once | `BindEventOnce` |
| Handle incoming invoke | `BindFunction` |
| Local one-shot listener | `BindLocalEventOnce` |
| Register send-only key | `RegisterEvent` (or fires auto-register) |

---

## Shared API (server + client)

### `Network:BindEvent(event, callback) → Cleanup`
### `Network:BindEvent(event, key, callback) → Cleanup`
Registers a cross-environment listener.
- Server callback: `(player: Player, data: any) -> ()`
- Client callback: `(data: any) -> ()`

```luau
-- multi-key
Network:BindEvent("Grid", "RequestGridData", function(player, data)
    Network:FireClient("Grid", player, "SendGridData", buildPayload())
end)

-- single-key (__main shorthand)
Network:BindEvent("Bomb", function(player, data)
    BombService.Place(player, data.x, data.y)
end)
```

### `Network:BindEventOnce(event, callback) → Cleanup`
### `Network:BindEventOnce(event, key, callback) → Cleanup`
Same as `BindEvent` but auto-disconnects after the first fire. Returns a Cleanup handle for early manual disconnection.

```luau
Network:BindEventOnce("Match", "Started", function(data)
    showCountdown(data.duration)
end)
```

### `Network:RegisterEvent(event)`
### `Network:RegisterEvent(event, key)`
Registers a send-only key so it receives an ID and is synced to clients, without attaching a listener. Auto-registration on first fire also handles this transparently — explicit calls only needed when you want the ID allocated before the first fire.

```luau
Network:RegisterEvent("Grid", "SendGridData")
Network:RegisterEvent("Grid", "UpdateGridTile")
```

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
In-process only. No remote involved. Ideal for client-side prediction or intra-service communication.

```luau
Network:BindLocalEvent("Movement", "Predicted", function(data)
    CharacterController.ApplyMove(data)
end)
```

### `Network:BindLocalEventOnce(event, callback) → Cleanup`
### `Network:BindLocalEventOnce(event, key, callback) → Cleanup`
Same as `BindLocalEvent` but auto-disconnects after the first fire.

### `Network:FireLocal(event, data)`
### `Network:FireLocal(event, key, data)`
Fires an in-process local event. Only `BindLocalEvent` / `BindLocalEventOnce` listeners on the same environment receive it.

```luau
Network:FireLocal("Movement", "Predicted", { x = 5, y = 3 })
```

---

## Server API

### `Network:FireAll(event, data)`
### `Network:FireAll(event, key, data)`
Enqueues a fire to every connected client. Flushed end of frame.

```luau
Network:FireAll("Grid", "UpdateGridTile", flatTile)
Network:FireAll("GameState", newState)   -- __main shorthand
```

### `Network:FireAllExcept(event, blacklist, data)`
### `Network:FireAllExcept(event, blacklist, key, data)`
Same as `FireAll` but skips one or more players. `blacklist` accepts a single `Player` or `{ Player }` array.

```luau
Network:FireAllExcept("Bomb", instigator, "Detonate", payload)
Network:FireAllExcept("Bomb", { p1, p2 }, payload)
```

### `Network:FireClient(event, client, data)`
### `Network:FireClient(event, client, key, data)`
Enqueues a fire to one or more specific clients. Accepts a single `Player` or `{ Player }` array.

```luau
Network:FireClient("Grid", player, "SendGridData", payload)
Network:FireClient("Notification", { p1, p2 }, message)
```

### `Network:InvokeClient(event, client, data) → Promise`
### `Network:InvokeClient(event, client, key, data) → Promise`
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
Enqueues a fire to the server. Flushed end of frame. If the event ID has not arrived yet (pre-sync), the fire is automatically queued and flushed once the ID is received — no packets are ever dropped.

```luau
Network:FireServer("Grid", "RequestGridData")
Network:FireServer("Bomb", { x = 3, y = 7 })
```

### `Network:InvokeServer(event, data) → Promise`
### `Network:InvokeServer(event, key, data) → Promise`
Invokes the server via RemoteFunction. **Not batched.** If the event ID has not arrived yet, the Promise waits reactively (via `_idRegistered` signal) with a 15-second timeout before rejecting.

```luau
Network:InvokeServer("Shop", "Purchase", { itemId = "shield_class" })
    :andThen(function(result) applyPurchase(result) end)
    :catch(function(err) warn("Purchase failed:", err) end)
```

---

## Cleanup

`BindEvent`, `BindEventOnce`, `BindFunction`, `BindLocalEvent`, and `BindLocalEventOnce` all return:

```luau
type Cleanup = { Disconnect: () -> () }
```

Always call `:Disconnect()` when the listener is no longer needed. Once-variant listeners auto-disconnect after their first fire, but the handle can still be used for early manual disconnection.

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
| Max unique event:key pairs | 65,535 (u16 ID space) |
| Invoke calls | Not batched — use sparingly |
| Client pre-sync fires | Auto-queued and flushed after sync |
| InvokeServer timeout | 15 seconds (rejects Promise on expiry) |
