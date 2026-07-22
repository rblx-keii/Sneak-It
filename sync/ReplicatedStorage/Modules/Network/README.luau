--!strict
--[[
+==============================================================================+
|                       NetworkLite -- API Reference                           |
|                       author: Keii  |  v2.0                                  |
+==============================================================================+

  A multiplexed, lightweight network layer. All traffic travels over two
  shared remotes (_R reliable, _U unreliable). Packets are batched per-frame
  and identified by a compact u16 event ID synced from server to client on join.

  Raw Luau data (tables, strings, numbers) is passed directly through Remotes.
  No serialization, no type checking, no blueprints.

=============================================================================
  ARCHITECTURE
=============================================================================

  Remotes         Four shared instances in ReplicatedStorage/_Remotes:
                    _R  (RemoteEvent)            -- reliable ordered traffic
                    _U  (UnreliableRemoteEvent)  -- unreliable traffic
                    _Invoke (RemoteFunction)     -- invoke calls, not batched
                    _Sync   (RemoteEvent)        -- ID table, server -> client

  Wire format     Flat array: { id1, payload1, id2, payload2, ... }
                  Flushed once per Heartbeat (server) / RenderStepped (client).

  Event IDs       u16, server-assigned (max 65 535 unique event:key pairs).
                  Full table sent to each client on join; incremental updates
                  sent when keys are registered after startup.

  Sync Model      Event-driven. An internal _idRegistered signal fires whenever
                  a new ID arrives on the client. FireServer queues packets when
                  an ID is missing and flushes them reactively once the sync
                  payload arrives. InvokeServer waits on the signal with a
                  15-second timeout -- no polling, no dropped packets.

  __main          Implicit key for single-key remotes.
                  Callers omit the key argument entirely when using __main.

  Module          Returns the Shared table. Internal state and helpers live in
  Structure       the Local table. Self-initializes on require via
                  Local._initialize() -- remotes and loops are ready immediately.

  Adaptive        Public methods dynamically detect whether a key is provided.
  Arg Resolution  If the second argument is a string, it is treated as the key.
                  Otherwise, it is treated as data and "__main" is used.

=============================================================================
  SHARED API  (server + client)
=============================================================================

  Network:BindEvent(event, callback)              -> Cleanup
  Network:BindEvent(event, key, callback)         -> Cleanup
  --------------------------------------------------------------------------
    Registers a cross-environment listener. Fires when the remote is received
    from the other side (server fires -> client receives, and vice-versa).

    Server callback signature:   (player: Player, data: any) -> ()
    Client callback signature:   (data: any) -> ()

    Returns a Cleanup handle -- call :Disconnect() to unsubscribe.

      -- multi-key
      Network:BindEvent("Grid", "RequestGridData", function(player, data)
          Network:FireClient("Grid", player, "SendGridData", buildPayload())
      end)

      -- single-key (__main shorthand)
      Network:BindEvent("Bomb", function(player, data)
          BombService.Place(player, data.x, data.y)
      end)


  Network:BindEventOnce(event, callback)          -> Cleanup
  Network:BindEventOnce(event, key, callback)     -> Cleanup
  --------------------------------------------------------------------------
    Same as BindEvent but auto-disconnects after the first fire. Uses the
    Signal:Once() primitive internally.

    Returns a Cleanup handle for early manual disconnection before it fires.

      Network:BindEventOnce("Match", "Started", function(data)
          showCountdown(data.duration)
      end)


  Network:RegisterEvent(event)
  Network:RegisterEvent(event, key)
  --------------------------------------------------------------------------
    Registers a send-only key so it receives an ID and is synced to clients,
    without attaching a listener callback. Use on the server for keys it only
    fires and never listens to, and on the client for keys it only fires to
    the server.

    Auto-registration also handles this transparently on first fire, so
    explicit RegisterEvent calls are only needed when you want the ID to be
    allocated before the first fire occurs.

      Network:RegisterEvent("Grid", "SendGridData")
      Network:RegisterEvent("Grid", "UpdateGridTile")


  Network:BindFunction(event, callback)           -> Cleanup
  Network:BindFunction(event, key, callback)      -> Cleanup
  --------------------------------------------------------------------------
    Registers a cross-environment invoke handler. The callback must return a
    value -- it is sent back to the invoking side as the response.

    Server callback signature:   (player: Player, data: any) -> any
    Client callback signature:   (data: any) -> any

      Network:BindFunction("Shop", "GetInventory", function(player, _data)
          return InventoryService.GetFor(player)
      end)


  Network:BindLocalEvent(event, callback)         -> Cleanup
  Network:BindLocalEvent(event, key, callback)    -> Cleanup
  --------------------------------------------------------------------------
    In-process only. No remote involved, same environment.
    Ideal for client-side prediction or intra-service communication.

      Network:BindLocalEvent("Movement", "Predicted", function(data)
          CharacterController.ApplyMove(data)
      end)


  Network:BindLocalEventOnce(event, callback)     -> Cleanup
  Network:BindLocalEventOnce(event, key, callback)-> Cleanup
  --------------------------------------------------------------------------
    Same as BindLocalEvent but auto-disconnects after the first fire. Uses
    Signal:Once() internally.

      Network:BindLocalEventOnce("Tutorial", "Complete", function(data)
          unlockRewards(data)
      end)


  Network:FireLocal(event, data)
  Network:FireLocal(event, key, data)
  --------------------------------------------------------------------------
    Fires an in-process local event. Only listeners registered via
    BindLocalEvent / BindLocalEventOnce on the same environment will receive it.

      Network:FireLocal("Movement", "Predicted", { x = 5, y = 3 })

=============================================================================
  SERVER API
=============================================================================

  Network:FireAll(event, data)
  Network:FireAll(event, key, data)
  --------------------------------------------------------------------------
    Enqueues a fire to every connected client. Flushed end of frame.

      Network:FireAll("Grid", "UpdateGridTile", flatTile)
      Network:FireAll("GameState", newState)       -- __main shorthand


  Network:FireAllExcept(event, blacklist, data)
  Network:FireAllExcept(event, blacklist, key, data)
  --------------------------------------------------------------------------
    Same as FireAll but skips one or more players.
    blacklist accepts a single Player or a { Player } array.

      Network:FireAllExcept("Bomb", instigator, "Detonate", payload)
      Network:FireAllExcept("Bomb", { p1, p2 }, payload)


  Network:FireClient(event, client, data)
  Network:FireClient(event, client, key, data)
  --------------------------------------------------------------------------
    Enqueues a fire to one or more specific clients. Flushed end of frame.
    Accepts a single Player instance or a { Player } array.

      Network:FireClient("Grid", player, "SendGridData", payload)
      Network:FireClient("Notification", { p1, p2 }, message)


  Network:InvokeClient(event, client, data)       -> Promise
  Network:InvokeClient(event, client, key, data)  -> Promise
  --------------------------------------------------------------------------
    Invokes a single client via RemoteFunction. Not batched -- fires immediately.
    Returns a Promise that resolves with the client's response or rejects on
    error. Use sparingly; client invokes can hang if the client is unresponsive.

      Network:InvokeClient("Dialog", player, prompt)
          :andThen(function(choice) handleChoice(player, choice) end)
          :catch(function(err) warn("InvokeClient failed:", err) end)

=============================================================================
  CLIENT API
=============================================================================

  Network:FireServer(event, data)
  Network:FireServer(event, key, data)
  --------------------------------------------------------------------------
    Enqueues a fire to the server. Flushed end of frame.
    If the event ID has not arrived yet (pre-sync or incremental), the fire
    is automatically queued and flushed once the ID is received. No packets
    are ever dropped.

      Network:FireServer("Grid", "RequestGridData")
      Network:FireServer("Bomb", { x = 3, y = 7 })


  Network:InvokeServer(event, data)               -> Promise
  Network:InvokeServer(event, key, data)          -> Promise
  --------------------------------------------------------------------------
    Invokes the server via RemoteFunction. Not batched -- fires immediately.
    Returns a Promise. If the event ID has not arrived yet, the Promise waits
    reactively (via _idRegistered signal) with a 15-second timeout before
    rejecting.

      Network:InvokeServer("Shop", "Purchase", { itemId = "shield_class" })
          :andThen(function(result) applyPurchase(result) end)
          :catch(function(err) warn("Purchase failed:", err) end)

=============================================================================
  CLEANUP
=============================================================================

  BindEvent, BindEventOnce, BindFunction, BindLocalEvent, and
  BindLocalEventOnce all return a Cleanup handle:

    type Cleanup = { Disconnect: () -> () }

  Call :Disconnect() when the listener is no longer needed. Failing to
  disconnect listeners on player removal will leak signal connections.
  Once-variant listeners auto-disconnect after their first fire, but the
  handle can still be used for early manual disconnection.

    local conn = Network:BindEvent("Bomb", handler)
    -- later:
    conn:Disconnect()

=============================================================================
  CONFIGURATION FLAGS  (top of init.luau)
=============================================================================

  DEBUG_TOGGLE    = true    Log bind/register/sync events. Set false in prod.
  VERBOSE_FLUSH   = false   Log every frame flush with byte estimates.
                            Enable only when diagnosing bandwidth -- expensive.

=============================================================================
  LIMITS
=============================================================================

  Max unique event:key pairs    65 535  (u16 ID space)
  Invoke calls                  Not batched -- use sparingly
  Client pre-sync fires         Automatically queued and flushed after sync
  InvokeServer timeout          15 seconds (rejects Promise on expiry)

=============================================================================
  QUICK REFERENCE
=============================================================================

  Goal                             Method
  -----------------------------    -----------------------------------------
  Server -> all clients             FireAll
  Server -> all except blacklist    FireAllExcept
  Server -> specific client(s)      FireClient
  Server -> client, expect response InvokeClient  (returns Promise)
  Client -> server                  FireServer
  Client -> server, expect response InvokeServer  (returns Promise)
  Same-env only (no remote)        FireLocal / BindLocalEvent
  Listen for incoming fire         BindEvent
  Listen once for incoming fire    BindEventOnce
  Handle incoming invoke           BindFunction
  Local one-shot listener          BindLocalEventOnce
  Register send-only key           RegisterEvent  (or fires auto-register)

]]

return nil
