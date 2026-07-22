--!strict
--[[
╔══════════════════════════════════════════════════════════════════════════════╗
║                         Observers — API Reference                            ║
║                         author: Keii                                         ║
╚══════════════════════════════════════════════════════════════════════════════╝

  Reactive lifecycle helpers for Roblox instances. Each observer watches a
  signal (property, attribute, tag, player, etc.), runs your callback when
  something becomes relevant, and tears down automatically when it does not.

  Every observer returns a stop function. Every callback may optionally return
  a cleanup function that runs when the observed value changes, the instance
  is removed, or the observer is stopped.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  MODULE STRUCTURE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  init.luau              Public entry point. Returns a table of observer
                         functions — no initialization side effects.

  _observe*.luau         Internal implementations. Required by init.luau only;
                         not part of the public surface.

  Dependencies           No external packages. Internal Roblox services only:
                           • Players          (_observePlayer, _observeCharacter,
                                              _observeLocalCharacter)
                           • RunService       (_observeLocalCharacter — client check)
                           • CollectionService (_observeTag)

  Composition            observeCharacter is built on top of observePlayer.
                         All other observers are independent.

  Usage

    local Observers = require(path.to.Observers)

    local stop = Observers.observeTag("Interactable", function(instance)
        -- setup
        return function()
            -- cleanup
        end
    end)

    -- later
    stop()

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SHARED CONVENTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Stop function          Every observer returns () -> ().
                         Calling it disconnects listeners and runs any active
                         cleanup callbacks.

  Callback cleanup       Callbacks may return () -> () or nil.
                         Returned cleanup runs when:
                           • the observed value/instance is no longer valid
                           • a newer value replaces the current one
                           • the observer is stopped manually

  Error handling         Callbacks run inside xpcall. Errors are warned with a
                         traceback; the observer keeps running.

  Guard predicates       Many observers accept an optional guard function to
                         filter which values/instances trigger the callback.
                         When omitted, all non-nil values pass (attributes also
                         skip nil values by default).

  Initial fire           Most observers defer an initial callback for existing
                         state (current property value, existing children,
                         already-tagged instances, connected players, etc.).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  API
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Observers.observePlayer(callback)                              -> () -> ()
  --------------------------------------------------------------------------
    Fires for every player currently in the game and for each player that joins
    later. Cleanup runs when the player leaves or the observer is stopped.

    Callback: (player: Player) -> (() -> ())?

      local stop = Observers.observePlayer(function(player)
          print("Joined:", player.Name)
          return function()
              print("Left:", player.Name)
          end
      end)


  Observers.observeCharacter(callback)                           -> () -> ()
  --------------------------------------------------------------------------
    Built on observePlayer. Fires when a player's character spawns and cleans
    up when the character is removed from the DataModel (not just when a new
    character replaces it mid-session — one active character per player at a
    time).

    Callback: (player: Player, character: Model) -> (() -> ())?

      local stop = Observers.observeCharacter(function(player, character)
          local humanoid = character:WaitForChild("Humanoid")
          print(player.Name, "spawned with", humanoid.Health, "HP")
          return function()
              print(player.Name, "character removed")
          end
      end)


  Observers.observeLocalCharacter(callback)                      -> () -> ()
  --------------------------------------------------------------------------
    Client-only. Same lifecycle as observeCharacter but for
    Players.LocalPlayer only. Asserts if called on the server.

    Callback: (character: Model) -> (() -> ())?

      local stop = Observers.observeLocalCharacter(function(character)
          CameraController.Attach(character)
          return function()
              CameraController.Detach()
          end
      end)


  Observers.observeTag(tag, callback, ancestors?)               -> () -> ()
  --------------------------------------------------------------------------
    Watches CollectionService tags. Fires for each tagged instance that passes
    the optional ancestor filter. Cleanup runs when the instance is destroyed,
    loses the tag, or moves outside allowed ancestors.

    Callback: (instance: Instance) -> (() -> ())?
    ancestors: { Instance }?  — when provided, only instances descended from
                                  one of these roots are observed.

      -- Observe interactables only while they live in Workspace
      local stop = Observers.observeTag("Interactable", function(prompt)
          local conn = prompt.Triggered:Connect(function(player)
              OpenShop(player)
          end)
          return function()
              conn:Disconnect()
          end
      end, { workspace })


  Observers.observeAttribute(instance, name, callback, guard?)    -> () -> ()
  --------------------------------------------------------------------------
    Watches a single attribute on an instance. Skips nil values. Fires on
    change and once for the current value on start.

    Callback: (value: any) -> (() -> ())?
    guard: (value: any) -> boolean?

      local stop = Observers.observeAttribute(model, "Health", function(hp)
          UpdateHealthBar(hp)
          return function()
              ClearHealthBar()
          end
      end, function(value)
          return typeof(value) == "number" and value >= 0
      end)


  Observers.observeAllAttributes(instance, callback, guard?)     -> () -> ()
  --------------------------------------------------------------------------
    Watches every attribute on an instance. Seeds from existing attributes on
    start, then fires on each subsequent change that passes the guard.

    Callback: (attributeName: string, value: any) -> (() -> ())?
    guard: (attributeName: string, value: any) -> boolean?

      local stop = Observers.observeAllAttributes(part, function(name, value)
          Config.Apply(name, value)
          return function()
              Config.Revert(name)
          end
      end, function(_name, value)
          return typeof(value) == "number"
      end)


  Observers.observeProperty(instance, propertyName, callback, guard?)
                                                                 -> () -> ()
  --------------------------------------------------------------------------
    Watches an instance property via GetPropertyChangedSignal. Fires on change
    and once for the current value on start.

    Callback: (value: any) -> (() -> ())?
    guard: (value: any) -> boolean?

      local stop = Observers.observeProperty(screenGui, "Enabled", function(on)
          if on then
              AnimateIn()
          end
          return function()
              AnimateOut()
          end
      end)


  Observers.observeChildren(instance, callback, guard?)          -> () -> ()
  --------------------------------------------------------------------------
    Fires for each direct child added to instance (including existing children
    on start). Cleanup runs when the child is removed or the observer stops.

    Callback: (child: Instance) -> (() -> ())?
    guard: (child: Instance) -> boolean?

      local stop = Observers.observeChildren(folder, function(part)
          Highlight(part)
          return function()
              Unhighlight(part)
          end
      end, function(child)
          return child:IsA("BasePart")
      end)


  Observers.observeDescendants(instance, callback, guard?)       -> () -> ()
  --------------------------------------------------------------------------
    Same lifecycle as observeChildren but for all descendants via
    DescendantAdded / DescendantRemoving.

    Callback: (descendant: Instance) -> (() -> ())?
    guard: (descendant: Instance) -> boolean?

      local stop = Observers.observeDescendants(model, function(part)
          RegisterCollider(part)
          return function()
              UnregisterCollider(part)
          end
      end, function(desc)
          return desc:IsA("BasePart") and desc.CanCollide
      end)


  Observers.observeClass(className, callback, root?)             -> () -> ()
  --------------------------------------------------------------------------
    Watches for instances of a Roblox class under root (default: game).
    Uses DescendantAdded / DescendantRemoving. Seeds existing matches on start.

    Callback: (instance: Instance) -> (() -> ())?
    root: Instance?  — defaults to game

      local stop = Observers.observeClass("ProximityPrompt", function(prompt)
          BindPrompt(prompt)
          return function()
              UnbindPrompt(prompt)
          end
      end, workspace)


  Observers.observeAncestry(instance, callback, guard?)          -> () -> ()
  --------------------------------------------------------------------------
    Watches AncestryChanged on a single instance. Skips changes where the
    instance is no longer in the DataModel. Seeds with the current parent on
    start.

    Callback: (changed: Instance, newParent: Instance?) -> (() -> ())?
    guard: (changed: Instance, newParent: Instance?) -> boolean?

      local stop = Observers.observeAncestry(tool, function(_tool, parent)
          if parent and parent:IsA("Model") then
              EquipEffects.Enable()
          end
          return function()
              EquipEffects.Disable()
          end
      end, function(_changed, newParent)
          return newParent ~= nil
      end)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  USE CASES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Player session management
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Track join/leave for leaderboards, teams, or per-player data stores.   │
  │                                                                         │
  │  Observers.observePlayer(function(player)                               │
  │      Leaderboard.Register(player)                                       │
  │      return function() Leaderboard.Unregister(player) end              │
  │  end)                                                                   │
  └─────────────────────────────────────────────────────────────────────────┘

  Character abilities and animations
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Attach ability scripts or animation controllers when characters spawn. │
  │                                                                         │
  │  Observers.observeCharacter(function(player, character)                 │
  │      local abilities = AbilityController.Bind(player, character)        │
  │      return function() abilities:Destroy() end                        │
  │  end)                                                                   │
  └─────────────────────────────────────────────────────────────────────────┘

  Client HUD tied to local character
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Drive UI from the local player's character without manual              │
  │  CharacterAdded wiring in every LocalScript.                            │
  │                                                                         │
  │  Observers.observeLocalCharacter(function(character)                    │
  │      local hud = Hud.new(character)                                     │
  │      return function() hud:Destroy() end                                │
  │  end)                                                                   │
  └─────────────────────────────────────────────────────────────────────────┘

  CollectionService-driven interactables
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Bind prompts, billboards, or proximity logic to tagged instances.      │
  │  Restrict to Workspace so prefabs in ServerStorage stay inert.          │
  │                                                                         │
  │  Observers.observeTag("ShopTerminal", function(terminal)              │
  │      ShopUI.Bind(terminal)                                              │
  │      return function() ShopUI.Unbind(terminal) end                      │
  │  end, { workspace })                                                    │
  └─────────────────────────────────────────────────────────────────────────┘

  Reactive config via attributes
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Drive behavior from designer-set attributes without polling.           │
  │                                                                         │
  │  Observers.observeAttribute(npc, "AggroRange", function(range)          │
  │      AggroSystem.SetRange(npc, range)                                   │
  │      return function() AggroSystem.Clear(npc) end                       │
  │  end)                                                                   │
  └─────────────────────────────────────────────────────────────────────────┘

  UI visibility from Enabled property
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  React to ScreenGui / Frame visibility changes cleanly.                 │
  │                                                                         │
  │  Observers.observeProperty(menu, "Enabled", function(enabled)           │
  │      if enabled then SoundService:PlayLocalSound(openSfx) end           │
  │  end)                                                                   │
  └─────────────────────────────────────────────────────────────────────────┘

  Dynamic part lists under a container
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Keep physics, highlights, or touch handlers in sync with a folder.   │
  │                                                                         │
  │  Observers.observeChildren(spawnFolder, function(spawnPoint)           │
  │      Spawner.Register(spawnPoint)                                       │
  │      return function() Spawner.Unregister(spawnPoint) end               │
  │  end)                                                                   │
  └─────────────────────────────────────────────────────────────────────────┘

  Hitbox / collider registration for a rig
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Register every BasePart under a model, including parts added later.    │
  │                                                                         │
  │  Observers.observeDescendants(rig, function(part)                      │
  │      HitboxService.Add(part)                                            │
  │      return function() HitboxService.Remove(part) end                   │
  │  end, function(desc) return desc:IsA("BasePart") end)                   │
  └─────────────────────────────────────────────────────────────────────────┘

  Global class sweep (prompts, seats, constraints)
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Attach behavior to every instance of a class under a subtree.          │
  │                                                                         │
  │  Observers.observeClass("Seat", function(seat)                          │
  │      SeatHandler.Setup(seat)                                            │
  │      return function() SeatHandler.Teardown(seat) end                   │
  │  end, workspace.Map)                                                    │
  └─────────────────────────────────────────────────────────────────────────┘

  Tool equip / reparent detection
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Run effects when a tool enters or leaves a character's hierarchy.      │
  │                                                                         │
  │  Observers.observeAncestry(tool, function(_, parent)                   │
  │      local equipped = parent and parent:FindFirstChild("Humanoid")      │
  │      if equipped then VFX.Attach(tool) end                              │
  │      return function() VFX.Detach(tool) end                             │
  │  end)                                                                   │
  └─────────────────────────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  QUICK REFERENCE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Goal                             Method
  -----------------------------    -----------------------------------------
  Player join / leave              observePlayer
  Any player's character           observeCharacter
  Local player's character         observeLocalCharacter  (client only)
  CollectionService tag            observeTag
  Single attribute                 observeAttribute
  All attributes on instance       observeAllAttributes
  Instance property                observeProperty
  Direct children                  observeChildren
  All descendants                  observeDescendants
  Instances of a class             observeClass
  Reparenting / ancestry           observeAncestry

  Stop an observer                 call the returned function
  Per-callback cleanup             return a function from your callback

]]

return nil
