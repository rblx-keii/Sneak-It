--|| Types
export type MobileButtonLayout = {
	scale: {number}, -- {X, Y}
	pos: {number}, -- {X, Y}
	transparency: number,
}

export type PlayerData = {
	stats: {
		coins: number,
		level: number,
		exp: number,
	},

	profile: {
		totalCoinsEarned: number,
		totalGamesPlayed: number,
		totalWins: number,
		smugglerWins: number,
		tsaWins: number,
		totalValueSmuggled: number,
		totalItemsSmuggled: number,
		successfulSearchEvades: number,
		totalArrests: number,
		totalSearches: number,
		successfulSearches: number,
		lastWinDate: string,
	},

	settings: {
		music: boolean,
		sfx: boolean,
	},

	mobileLayout: {
		[string]: MobileButtonLayout,
	},

	-- Equipped perk per team (PerksConfig), kept separate so switching teams between rounds
	-- doesn't clear the other team's selection, plus the consumable itemStock selected to bring
	-- into the next round (capped: 3 if Smuggler has DuffleBag equipped, else 1; TSA always 1).
	loadout: {
		Smuggler: string?,
		TSA: string?,
		consumables: { string },
	},

	-- Unlocked perks (see PerksConfig) — "does this player have permanent access to this perk."
	ownedItems: {
		[string]: boolean,
	},

	-- Purchased shop consumables (see ShopConfig), itemName -> quantity currently in stock.
	-- Repeat purchases increment the count; equipping into loadout.consumables does not deduct it
	-- yet (round-start consumption is a separate, not-yet-built system).
	itemStock: {
		[string]: number,
	},

	tutorial: {
		completed: boolean,
	},
	
	afk: boolean,
}

local PLAYER_DATA_TEMPLATE: PlayerData = {
	stats = {
		coins = 0,
		level = 1,
		exp = 0,
	},

	profile = {
		totalCoinsEarned = 0,
		totalGamesPlayed = 0,
		totalWins = 0,
		smugglerWins = 0,
		tsaWins = 0,
		totalValueSmuggled = 0,
		totalItemsSmuggled = 0,
		successfulSearchEvades = 0,
		totalArrests = 0,
		totalSearches = 0,
		successfulSearches = 0,
		lastWinDate = "",
	},

	settings = {
		music = true,
		sfx = true,
	},

	mobileLayout = {},

	-- Free/default perks (PerksConfig winsRequired = 0) start owned and equipped.
	loadout = {
		Smuggler = "DuffleBag",
		TSA = "ScannerWand",
		consumables = {},
	},

	ownedItems = {
		DuffleBag = true,
		ScannerWand = true,
	},

	itemStock = {},

	tutorial = {
		completed = false,
	},
	
	afk = false,
}

return {
	PLAYER_DATA_TEMPLATE = PLAYER_DATA_TEMPLATE,
}