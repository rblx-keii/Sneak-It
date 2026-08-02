--|| Types
export type ShopCategory = "Consumables" | "Utility" | "Chaos"

export type ShopEntry = {
	itemName: string, -- ItemsConfig key
	displayName: string,
	description: string,
	price: number, -- Coins ("Tokens")
	category: ShopCategory,
}

--|| MAIN ||--
local ShopConfig = {}

-- Placeholder catalog — first-draft prices/copy, not final balance. DuffleBag/ScannerWand also exist
-- as PerksConfig entries; buying them here is a separate path that just grants regular-pick stock.
ShopConfig.Entries = {
	{ itemName = "DoubleEspresso", displayName = "Double Espresso", description = "Temporarily increases your speed — helps chase down fleeing Smugglers.", price = 300, category = "Consumables" },

	{ itemName = "PaddedJacket", displayName = "Padded Vest", description = "Softens the impact of a ragdoll or fall.", price = 200, category = "Utility" },
	{ itemName = "DuffleBag", displayName = "Duffle Bag", description = "Roomy contraband storage — carry up to 3 items at once.", price = 500, category = "Utility" },
	{ itemName = "Briefcase", displayName = "Briefcase", description = "A smaller, lower-profile alternative to the duffel bag.", price = 350, category = "Utility" },
	{ itemName = "ScannerWand", displayName = "Scanner Wand", description = "Scan players to check whether they're carrying contraband.", price = 450, category = "Utility" },

	{ itemName = "FireExtinguisher", displayName = "Fire Extinguisher", description = "Spray a blinding foam cloud to block vision and slow pursuers.", price = 250, category = "Chaos" },
	{ itemName = "AirHorn", displayName = "Air Horn", description = "Blast a deafening honk to startle nearby players.", price = 150, category = "Chaos" },
	{ itemName = "StinkBurst", displayName = "Stink Grenade", description = "Throw to release a foul cloud that disorients anyone caught in it.", price = 150, category = "Chaos" },
	{ itemName = "SmokeBurst", displayName = "Smoke Grenade", description = "Throw to create a thick smoke cloud — block vision, escape Security, or cause chaos.", price = 200, category = "Chaos" },
	{ itemName = "OverchargedBattery", displayName = "Overcharged Battery", description = "A jury-rigged power cell with a risky kick.", price = 250, category = "Chaos" },
} :: { ShopEntry }

-- [[ Public Functions ]] --
function ShopConfig.GetEntry(itemName: string): ShopEntry?
	for _, entry in ShopConfig.Entries do
		if entry.itemName == itemName then
			return entry
		end
	end
	return nil
end

function ShopConfig.GetCategoryEntries(category: ShopCategory): { ShopEntry }
	local result = {}
	for _, entry in ShopConfig.Entries do
		if entry.category == category then
			table.insert(result, entry)
		end
	end
	return result
end

return ShopConfig
