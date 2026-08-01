1. System Overview
The game will have two main item systems:
Perks are permanent unlocks that players equip before a round. They are unlocked through wins, or can be purchased instantly with Robux to bypass the win requirement. Perks are tied to the player’s team role.
Consumables are one-time-use items that can be purchased before a round using Terminal Tokens. These only last for that round and can be used, dropped, thrown, or deposited by Smugglers.
The goal is to keep the system simple while still giving players progression, strategy, and monetization opportunities.

2. Inventory & Perk Hotbar System
Players will have two main item sections during a round:
1. Inventory Items
These are normal items the player is carrying.
Inventory items can include:
Duffel Bags
Briefcases
stolen items
map-spawned items
purchased consumables
items collected during the round
Inventory items can usually be held, thrown, dropped, stored, or deposited depending on the item type.
For Smugglers, the inventory will often include the Duffel Bag or Briefcase used to carry stolen items.

2. Perk Items
Perk items will appear in their own separate section of the hotbar.
These are the player’s equipped loadout items for that round.
Examples:
Fake Boarding Pass
Smoke Bomb
Scanner Wand
Double Espresso
Wet Floor Sign
Perk items are separate from normal inventory items. They cannot be deposited at the gate and do not count toward Smuggler score.
Players can cycle between their perk item and their normal inventory item.
For example, a Smuggler may be able to switch between:
their equipped perk item, if it has not been used yet
their Duffel Bag or other inventory item
The Duffel Bag is the main exception. Even though it can be selected as a perk, it appears in the player’s normal inventory automatically instead of the separate perk hotbar section. However, the perk-spawned Duffel Bag still cannot be deposited for score.

3. Perk System
Perks are permanent unlocks.
Players can unlock perks in two ways:
by earning the required number of wins
by purchasing the perk instantly with Robux
Each team has its own set of perks:
Smuggler perks
Security perks
Players may only equip one perk for the team they are playing.
The first perk for each team is free/default. The other perks are unlocked later through wins or Robux purchase.
Perk items are not meant to be sold or deposited for Smuggler score. They exist as loadout tools to help the player during the round.

4. Smuggler Perks
1. Empty Duffel Bag
Tier: Free / Default
 Type: Starter perk
 Purpose: Convenience / safer start
The player spawns with a Duffel Bag already equipped. This lets the Smuggler immediately start collecting items without needing to steal/find a bag from an NPC or around the airport.
If a player does not choose this perk, they can still find Duffel Bags or Briefcases around the airport.
The Duffel Bag is treated like a normal inventory item once equipped, but the perk version itself cannot be deposited for score.

2. Fake Boarding Pass
Tier: Mid-tier unlock
 Type: Single-use tool
 Purpose: Checkpoint bypass
When used, the Fake Boarding Pass temporarily prevents the security scanner/metal detector from alarming.
Effect:
IgnoreAlarm = true for 3 seconds
This gives Smugglers a short window to pass through security without triggering the alarm.
The perk version cannot be dropped or deposited.

3. Smoke Bomb
Tier: Premium unlock
 Type: Single-use throwable
 Purpose: Escape / visual chaos
The Smoke Bomb can be thrown to create a thick smoke cloud on impact.
It is used to block vision, escape Security, distract players, or create chaos near the checkpoint/gate.
The perk version cannot be deposited for score.

5. Security Perks
1. Scanner Wand
Tier: Free / Default
 Type: Starter perk
 Purpose: Detection
Security players can spawn with a Scanner Wand.
The Scanner Wand allows Security to scan players and check whether they are carrying contraband.
If a player is clean, it plays a green/clean beep.
If a player has contraband, it plays a red/buzzer sound.
If a Security player does not choose this perk, Scanner Wands can still spawn around the airport and be picked up during the round.
The perk version cannot be dropped or deposited.

2. Double Espresso
Tier: Mid-tier unlock
 Type: Single-use consumable perk
 Purpose: Chase boost
When used, Double Espresso temporarily increases the player’s speed.
Effect:
WalkSpeed increases to 24 for 8 seconds
 This can be changed later based on gameplay testing.
This helps Security chase down fleeing Smugglers.
The perk version cannot be dropped or deposited.

3. Wet Floor Sign
Tier: Premium unlock
 Type: Deployable trap
 Purpose: Crowd control / stopping runners
The Wet Floor Sign can be placed down as a trap.
If a player from the opposite team walks near it, it creates a spill and causes them to slip/ragdoll for a short time.
Effect:
2-second ragdoll
 This can be changed later based on gameplay testing.
The perk version cannot be deposited for score.

6. Perk Rules
Perks are permanent unlocks.
Perks can be unlocked through wins.
Perks can also be purchased instantly with Robux to bypass the win requirement.
Each team has 3 perks.
Players can only equip one perk for their team.
The free/default perks are Duffel Bag for Smugglers and Scanner Wand for Security.
If a player does not equip the basic perk, they can still find that item around the airport.
Perk items cannot be deposited at the gate.
Perk items do not count toward Smuggler score.
Perk items have their own dedicated hotbar/ability section.
The Duffel Bag is the exception because it appears in the player’s normal inventory, but it still does not count as a depositable score item when spawned as a perk.

7. Consumable Shop System
Consumables are one-time-use items that players can buy before the round starts.
These are not permanent perks. They only last for the current round.
Players can bring a maximum of:
3 consumables per round
Consumables are purchased using Terminal Tokens.
These items are meant to give players a small advantage, create chaos, or help them complete their objective.

8. Consumable Rules
Consumables can be:
used
thrown
dropped
carried
stored in bags, if applicable
deposited at the gate by Smugglers
Unlike perk items, consumables can be deposited for stars if the player is a Smuggler.
This means players who grind a lot or spend Robux to buy currency can gain a slight advantage by bringing useful consumables into the round.
However, because players can only bring 3 consumables per round, it should not instantly win the round for them.
