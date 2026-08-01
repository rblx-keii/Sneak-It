--|| Types
export type QuestCategory = "Daily" | "Weekly"

-- Matches the `key` UpdateData's "UpdateProfile" action is already called with across the
-- codebase (ArrestService/ScannerWand/DepositService/RewardService) — quest progress just
-- listens for those same calls rather than tracking anything new.
export type QuestObjective =
	"totalArrests"
	| "totalSearches"
	| "successfulSearches"
	| "successfulSearchEvades"
	| "totalValueSmuggled"
	| "totalItemsSmuggled"
	| "totalGamesPlayed"
	| "totalWins"
	| "smugglerWins"
	| "tsaWins"

export type QuestEntry = {
	id: string,
	category: QuestCategory,
	displayName: string,
	description: string,
	objective: QuestObjective,
	target: number,
	reward: number, -- Coins ("Tokens")
}

--|| MAIN ||--
local QuestsConfig = {}

-- Placeholder catalog — first-draft targets/rewards for tuning, not final balance. Daily draws 3
-- at random per player per day; Weekly draws 1 at random per player per week (see QuestService).
QuestsConfig.Entries = {
	{ id = "Arrests_3", category = "Daily", displayName = "Cuff 'Em", description = "Arrest 3 Smugglers.", objective = "totalArrests", target = 3, reward = 150 },
	{ id = "Searches_5", category = "Daily", displayName = "Thorough Inspection", description = "Search 5 players.", objective = "totalSearches", target = 5, reward = 100 },
	{ id = "SuccessfulSearches_3", category = "Daily", displayName = "Sharp Eye", description = "Catch 3 Smugglers red-handed in a search.", objective = "successfulSearches", target = 3, reward = 150 },
	{ id = "Evades_3", category = "Daily", displayName = "Slippery", description = "Evade 3 searches while smuggling.", objective = "successfulSearchEvades", target = 3, reward = 150 },
	{ id = "Smuggle_500", category = "Daily", displayName = "Big Score", description = "Smuggle $500 worth of contraband.", objective = "totalValueSmuggled", target = 500, reward = 200 },
	{ id = "SmuggleItems_5", category = "Daily", displayName = "Pack Mule", description = "Smuggle 5 items past Security.", objective = "totalItemsSmuggled", target = 5, reward = 150 },
	{ id = "Games_3", category = "Daily", displayName = "Regular", description = "Play 3 rounds.", objective = "totalGamesPlayed", target = 3, reward = 100 },
	{ id = "Wins_1", category = "Daily", displayName = "Victory", description = "Win 1 round.", objective = "totalWins", target = 1, reward = 150 },
	{ id = "SmugglerWins_1", category = "Daily", displayName = "Clean Getaway", description = "Win 1 round as a Smuggler.", objective = "smugglerWins", target = 1, reward = 100 },
	{ id = "TsaWins_1", category = "Daily", displayName = "Lockdown", description = "Win 1 round as TSA.", objective = "tsaWins", target = 1, reward = 100 },

	{ id = "Arrests_20", category = "Weekly", displayName = "Terminal Person", description = "Arrest 20 Smugglers.", objective = "totalArrests", target = 20, reward = 700 },
	{ id = "Searches_30", category = "Weekly", displayName = "Never Off Duty", description = "Search 30 players.", objective = "totalSearches", target = 30, reward = 600 },
	{ id = "Smuggle_3000", category = "Weekly", displayName = "Kingpin", description = "Smuggle $3,000 worth of contraband.", objective = "totalValueSmuggled", target = 3000, reward = 900 },
	{ id = "Wins_7", category = "Weekly", displayName = "Weekly Champion", description = "Win 7 rounds.", objective = "totalWins", target = 7, reward = 800 },
	{ id = "Games_15", category = "Weekly", displayName = "Frequent Flyer", description = "Play 15 rounds.", objective = "totalGamesPlayed", target = 15, reward = 500 },
} :: { QuestEntry }

-- [[ Public Functions ]] --
function QuestsConfig.GetEntry(id: string): QuestEntry?
	for _, entry in QuestsConfig.Entries do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

function QuestsConfig.GetCategoryEntries(category: QuestCategory): { QuestEntry }
	local result = {}
	for _, entry in QuestsConfig.Entries do
		if entry.category == category then
			table.insert(result, entry)
		end
	end
	return result
end

function QuestsConfig.GetRandomIds(category: QuestCategory, count: number): { string }
	local pool = QuestsConfig.GetCategoryEntries(category)
	local result = {}

	for _ = 1, math.min(count, #pool) do
		local index = math.random(1, #pool)
		table.insert(result, pool[index].id)
		table.remove(pool, index)
	end

	return result
end

return QuestsConfig
