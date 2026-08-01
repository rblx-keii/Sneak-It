--|| Types
export type Team = "Smuggler" | "TSA" -- matches TeamService.TeamName; "Security" in the design doc is TSA's display name

export type PerkEntry = {
	itemName: string, -- ItemsConfig key
	team: Team,
	displayName: string,
	description: string,
	winsRequired: number, -- 0 = free/default, already owned from PlayerDataTemplate
	robuxProductId: number?, -- MonetizationService DevProduct id; nil until a real product is created
}

--|| MAIN ||--
local PerksConfig = {}

-- Placeholder catalog — win thresholds and descriptions are first-draft values for tuning, not
-- final balance. itemName -> ItemsConfig mapping: "Smoke Bomb" has no dedicated item yet, mapped
-- to the closest existing effect (SmokeBurst).
PerksConfig.Entries = {
	{
		itemName = "DuffleBag",
		team = "Smuggler",
		displayName = "Empty Duffel Bag",
		description = "Spawn with a Duffel Bag already equipped, so you can start collecting items immediately.",
		winsRequired = 0,
	},
	{
		itemName = "FakeBoardingPass",
		team = "Smuggler",
		displayName = "Fake Boarding Pass",
		description = "Prevents the security scanner from alarming for a few seconds when used.",
		winsRequired = 5,
		robuxProductId = nil,
	},
	{
		itemName = "SmokeBurst",
		team = "Smuggler",
		displayName = "Smoke Bomb",
		description = "Throw to create a thick smoke cloud — block vision, escape Security, or cause chaos.",
		winsRequired = 15,
		robuxProductId = nil,
	},
	{
		itemName = "ScannerWand",
		team = "TSA",
		displayName = "Scanner Wand",
		description = "Scan players to check whether they're carrying contraband.",
		winsRequired = 0,
	},
	{
		itemName = "DoubleEspresso",
		team = "TSA",
		displayName = "Double Espresso",
		description = "Temporarily increases your speed — helps chase down fleeing Smugglers.",
		winsRequired = 5,
		robuxProductId = nil,
	},
	{
		itemName = "WetFloorSign",
		team = "TSA",
		displayName = "Wet Floor Sign",
		description = "Place down as a trap — causes the opposite team to slip and ragdoll briefly.",
		winsRequired = 15,
		robuxProductId = nil,
	},
} :: { PerkEntry }

-- [[ Public Functions ]] --
function PerksConfig.GetEntry(itemName: string): PerkEntry?
	for _, entry in PerksConfig.Entries do
		if entry.itemName == itemName then
			return entry
		end
	end
	return nil
end

function PerksConfig.GetTeamEntries(team: Team): { PerkEntry }
	local result = {}
	for _, entry in PerksConfig.Entries do
		if entry.team == team then
			table.insert(result, entry)
		end
	end
	return result
end

function PerksConfig.GetEntryByProductId(productId: number): PerkEntry?
	for _, entry in PerksConfig.Entries do
		if entry.robuxProductId == productId then
			return entry
		end
	end
	return nil
end

return PerksConfig
