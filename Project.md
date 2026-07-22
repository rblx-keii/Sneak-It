1. Core Game Loop & Objectives
Match Duration: 10 Minutes per round.
The Smugglers' Objective: Successfully smuggle a total of $10,000 worth of contraband/items past the security checkpoint and deposit them at the final gate before the timer runs out.
The Security (TSA) Objective: Identify, intercept, and arrest the Smugglers to prevent them from reaching the $10,000 threshold before the 10-minute timer expires.
2. Matchmaking & Lobby System
Main Lobby Map: Players join a central hub/lobby space.
Queueing: Players walk into designated queue boxes/zones.
Teleportation: After a set countdown timer, the system groups the players inside the box and teleports them together into a live game subplace (reserved server) to start the match.
3. Map Layout (Launch Map)
The map is a linear, single-floor airport terminal designed to funnel players through specific chokepoints.
Zone A: Check-In Hall (Smuggler Spawn): A safe zone where Smugglers and NPCs spawn. Security agents are physically blocked from entering this area.
Zone B: Security Checkpoint: The main bottleneck where TSA players operate, featuring metal detectors and scanners.
Zone C: The Airside Concourse:
Left Side: Restaurants and Duty-Free shops (This is where players scavenge items like perfume bottles, container food, drinks, etc.).
Right Side: Dummy boarding gates with glass windows looking out at static parked aircraft.
Center: The Jail/Holding Cell where penalized Security agents and arrested Smugglers are temporarily held.
Zone D: The Final Gate: The drop-off point where Smugglers deposit items to add to the team's $10,000 quota.
4. Team Mechanics & AI
Team A: The Smugglers
Must blend in with the NPC crowd to cross the checkpoint.
Scavenge shops, load up bags, and deposit items at the gate.
If tackled/caught by Security, they are sent to the map's central Jail for a set duration before respawning.
Team B: Security (TSA)
Must monitor the crowd, sniff out suspicious player movement, and tackle/arrest Smugglers.
The 3-Strike System: Tackling or arresting an innocent NPC registers as a "strike."
If an agent hits 3 strikes, they are instantly teleported to the central Jail for a set duration (leaving the checkpoint unguarded).
NPC AI & Environmental Events
NPC Behavior: The terminal is filled with Roblox dummy NPCs to provide cover for the Smugglers. They pathfind toward the gates, randomly perform dance emotes to confuse Security, and occasionally steal luggage from one another.
The Gate Lockdown Sequence: There is a button/prompt at the main gate that can be triggered by either Smugglers or Security. Once initiated, it locks the gate doors completely for 10 seconds. Triggering this causes all NPCs in the vicinity to enter a "panic mode," running around erratically to create massive visual chaos.
5. Inventory & Base Item Mechanics
Base Inventory: A player can only carry one item at a time in their hands.
Interaction: Items are picked up by holding an interact prompt (e.g., holding 'E'). Once selected, players can hold the item or use an alternate input to throw it a short distance.
The Bag System: Smugglers can steal duffel bags or suitcases from walking NPCs. Equipping a bag allows the player to hold an interact prompt on an item to store it inside. Drawback: Placing an item in a bag triggers a loud "zipper" sound effect that alerts nearby Security.
Map Spawns (Chaos Items): Items like smoke bombs, toy guns, and dynamite spawn randomly around the map and can be picked up and utilized by both teams.
6. Pre-Spawn Loadouts & Progression
Before spawning, players can select one starting item from their team's loadout menu.
🎒 Team Smugglers Loadout
1. Empty Duffel Bag (Free / Default): The player spawns with a bag already equipped, bypassing the need to risk stealing one from an NPC in the Check-In Hall.
2. Fake Boarding Pass (Unlockable - Mid Tier): A single-use tool. When clicked, it sets an attribute (IgnoreAlarm = true) for 3 seconds so the TSA metal detector will not go off when they walk through.
3. Smoke Bomb (Unlockable - Premium): A throwable item that spawns a ParticleEmitter on impact, creating a massive, thick grey cloud for 10 seconds to create visual chaos.
🛂 Team Security (TSA) Loadout
1. Scanner Wand (Free / Default): Uses basic raycasting/Mouse.Target. When clicked on a character, it plays a "Green/Beep" sound if clean, and a loud "Red/Buzzer" sound if they have the HasContraband attribute.
2. Double Espresso (Unlockable - Mid Tier): A consumable drink. Temporarily increases the player's Humanoid.WalkSpeed from default to 24 for 8 seconds to chase fleeing targets.
3. "Wet Floor" Sign (Unlockable - Premium): A deployable trap. Uses a basic .Touched event. Anyone who steps on it is forced into a 2-second ragdoll state.
7. Economy & Monetization Strategy
Currency: Terminal Tokens. Earned automatically at the end of the round (+50 Tokens for a win, +10 Tokens per arrest/successful smuggle).
The Unlock Loop: Mid-tier items (Fake Boarding Pass, Espresso) cost an accessible amount of Tokens (e.g., 200 Tokens) to encourage a healthy 4-5 round grind. 
Premium Items & DevProducts: High-tier chaos items (Smoke Bomb, Wet Floor Sign) cost a large amount of Tokens (e.g., 2,000) OR can be unlocked instantly via a Robux DevProduct.