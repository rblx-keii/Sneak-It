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

-- Placeholder catalog — first-draft prices/categories/copy for tuning, not final balance. Perk
-- items (see PerksConfig) are deliberately excluded: those are unlocked via wins/Robux, not bought
-- here.
ShopConfig.Entries = {
	{ itemName = "AirHorn", displayName = "Air Horn", description = "Blast a deafening honk to startle nearby players.", price = 150, category = "Chaos" },
	{ itemName = "StinkBurst", displayName = "Stink Burst", description = "Release a foul cloud that disorients anyone caught in it.", price = 150, category = "Chaos" },
	{ itemName = "ToyGun", displayName = "Toy Gun", description = "Looks real enough to cause a scene.", price = 200, category = "Chaos" },
	{ itemName = "FireExtinguisher", displayName = "Fire Extinguisher", description = "Spray a blinding foam cloud to block vision and slow pursuers.", price = 250, category = "Utility" },
	{ itemName = "OverchargedBattery", displayName = "Overcharged Battery", description = "A jury-rigged power cell with a risky kick.", price = 250, category = "Utility" },
	{ itemName = "PaddedJacket", displayName = "Padded Jacket", description = "Softens the impact of a ragdoll or fall.", price = 200, category = "Utility" },
	{ itemName = "Pizza", displayName = "Pizza", description = "A greasy slice. Purely for flavor.", price = 75, category = "Consumables" },
	{ itemName = "BurgerBox", displayName = "Burger Box", description = "Fast food in a box. Purely for flavor.", price = 75, category = "Consumables" },
	{ itemName = "ChipBag", displayName = "Chip Bag", description = "A crinkly bag of chips. Purely for flavor.", price = 50, category = "Consumables" },
	{ itemName = "SodaCup", displayName = "Soda Cup", description = "A fizzy drink. Purely for flavor.", price = 50, category = "Consumables" },
	{ itemName = "WaterBottle", displayName = "Water Bottle", description = "Stays sealed and TSA-approved. Purely for flavor.", price = 40, category = "Consumables" },
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
