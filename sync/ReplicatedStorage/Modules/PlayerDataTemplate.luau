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

	loadout: string?,

	ownedItems: {
		[string]: boolean,
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

	loadout = nil,

	ownedItems = {},

	tutorial = {
		completed = false,
	},
	
	afk = false,
}

return {
	PLAYER_DATA_TEMPLATE = PLAYER_DATA_TEMPLATE,
}