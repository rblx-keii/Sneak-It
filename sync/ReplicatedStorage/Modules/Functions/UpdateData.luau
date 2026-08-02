local PlayerDataTemplate = require(script.Parent.Parent.PlayerDataTemplate)

export type PlayerData = PlayerDataTemplate.PlayerData

export type UpdateAction = {
	type:
		"AddCoins"
	| "SpendCoins"
	| "AddExp"
	| "UpdateStat"
	| "UpdateProfile"
	| "UpdateSettings"
	| "UpdateMobileLayout"
	| "SetLoadout"
	| "AddOwnedItem"
	| "RemoveOwnedItem"
	| "AddItemStock"
	| "RemoveItemStock"
	| "SetConsumableLoadout"
	| "AssignQuests"
	| "SetQuestProgress"
	| "ClaimQuest"
	| "CompleteTutorial"
	| "SetLastWinDate",

	data: {
		[string]: any?,
	},
}

return function(playerData: PlayerData, action: UpdateAction)
	if action.type == "AddCoins" then
		local amount = action.data.amount
		assert(typeof(amount) == "number" and amount > 0, "AddCoins: amount must be a positive number")

		playerData.stats.coins += amount
		playerData.profile.totalCoinsEarned += amount

	elseif action.type == "SpendCoins" then
		local amount = action.data.amount
		assert(typeof(amount) == "number" and amount > 0, "SpendCoins: amount must be a positive number")
		assert(playerData.stats.coins >= amount, "SpendCoins: insufficient coins")

		playerData.stats.coins -= amount

	elseif action.type == "AddExp" then
		local amount = action.data.amount
		assert(typeof(amount) == "number" and amount > 0, "AddExp: amount must be a positive number")

		playerData.stats.exp += amount

	elseif action.type == "SetLevel" then
		local level = action.data.level
		assert(typeof(level) == "number" and level >= 1, "SetLevel: level must be >= 1")

		playerData.stats.level = level
		playerData.stats.exp = action.data.remainingExp or 0

	elseif action.type == "UpdateProfile" then
		local key = action.data.key
		local amount = action.data.amount

		assert(typeof(key) == "string", "UpdateProfile: key must be a string")
		assert(playerData.profile[key] ~= nil, `UpdateProfile: key "{key}" not found in profile`)
		assert(typeof(amount) == "number", "UpdateProfile: amount must be a number")

		playerData.profile[key] += amount

	elseif action.type == "UpdateSettings" then
		local key = action.data.key
		local value = action.data.value

		assert(typeof(key) == "string" and value ~= nil, "UpdateSettings: missing key or value")
		assert(playerData.settings[key] ~= nil, `UpdateSettings: setting "{key}" not found`)
		assert(
			typeof(value) == typeof(playerData.settings[key]),
			`UpdateSettings: expected {typeof(playerData.settings[key])}, got {typeof(value)}`
		)

		playerData.settings[key] = value

	elseif action.type == "UpdateMobileLayout" then
		local buttonId = action.data.buttonId
		local layout = action.data.layout

		assert(typeof(buttonId) == "string" and buttonId ~= "", "UpdateMobileLayout: buttonId must be a non-empty string")
		assert(typeof(layout) == "table", "UpdateMobileLayout: layout must be a table")
		assert(typeof(layout.scale) == "table" and #layout.scale == 2, "UpdateMobileLayout: scale must be {X, Y}")
		assert(typeof(layout.pos) == "table" and #layout.pos == 2, "UpdateMobileLayout: pos must be {X, Y}")
		assert(typeof(layout.transparency) == "number", "UpdateMobileLayout: transparency must be a number")

		playerData.mobileLayout[buttonId] = {
			scale = layout.scale,
			pos = layout.pos,
			transparency = math.clamp(layout.transparency, 0, 1),
		}

	elseif action.type == "SetLoadout" then
		local team = action.data.team
		local itemName = action.data.itemName

		assert(team == "Smuggler" or team == "TSA", `SetLoadout: team must be "Smuggler" or "TSA"`)

		if itemName == nil then
			playerData.loadout[team] = nil
			return
		end

		assert(typeof(itemName) == "string" and itemName ~= "", "SetLoadout: itemName must be a non-empty string or nil")
		assert(playerData.ownedItems[itemName] == true, `SetLoadout: item "{itemName}" not owned`)

		playerData.loadout[team] = itemName

	elseif action.type == "AddOwnedItem" then
		local itemName = action.data.itemName
		assert(typeof(itemName) == "string" and itemName ~= "", "AddOwnedItem: itemName must be a non-empty string")

		playerData.ownedItems[itemName] = true

	elseif action.type == "RemoveOwnedItem" then
		local itemName = action.data.itemName
		assert(typeof(itemName) == "string" and itemName ~= "", "RemoveOwnedItem: itemName must be a non-empty string")

		playerData.ownedItems[itemName] = nil

		if playerData.loadout.Smuggler == itemName then
			playerData.loadout.Smuggler = nil
		end
		if playerData.loadout.TSA == itemName then
			playerData.loadout.TSA = nil
		end

	elseif action.type == "AddItemStock" then
		local itemName = action.data.itemName
		local amount = action.data.amount
		assert(typeof(itemName) == "string" and itemName ~= "", "AddItemStock: itemName must be a non-empty string")
		assert(typeof(amount) == "number" and amount > 0, "AddItemStock: amount must be a positive number")

		playerData.itemStock[itemName] = (playerData.itemStock[itemName] or 0) + amount

	elseif action.type == "RemoveItemStock" then
		local itemName = action.data.itemName
		local amount = action.data.amount or 1
		assert(typeof(itemName) == "string" and itemName ~= "", "RemoveItemStock: itemName must be a non-empty string")
		assert(typeof(amount) == "number" and amount > 0, "RemoveItemStock: amount must be a positive number")

		local remaining = math.max((playerData.itemStock[itemName] or 0) - amount, 0)

		if remaining <= 0 then
			playerData.itemStock[itemName] = nil

			-- Stock-depleted items shouldn't silently keep granting for free — drop from the loadout too.
			local consumables = playerData.loadout.consumables
			for i = #consumables, 1, -1 do
				if consumables[i] == itemName then
					table.remove(consumables, i)
				end
			end
		else
			playerData.itemStock[itemName] = remaining
		end

	elseif action.type == "SetConsumableLoadout" then
		local itemNames = action.data.itemNames
		assert(typeof(itemNames) == "table", "SetConsumableLoadout: itemNames must be a table")

		-- 3 unique items if the Smuggler perk slot has DuffleBag equipped, 1 otherwise (TSA has no
		-- equivalent perk, so it's always capped at 1).
		local cap = if playerData.loadout.Smuggler == "DuffleBag" then 3 else 1
		assert(#itemNames <= cap, `SetConsumableLoadout: exceeds cap of {cap}`)

		local seen: { [string]: boolean } = {}
		for _, itemName in itemNames do
			assert(typeof(itemName) == "string" and itemName ~= "", "SetConsumableLoadout: itemName must be a non-empty string")
			assert(not seen[itemName], `SetConsumableLoadout: duplicate item "{itemName}"`)
			assert((playerData.itemStock[itemName] or 0) > 0, `SetConsumableLoadout: item "{itemName}" not in stock`)
			seen[itemName] = true
		end

		playerData.loadout.consumables = itemNames

	elseif action.type == "AssignQuests" then
		local category = action.data.category
		local resetId = action.data.resetId
		local ids = action.data.ids

		assert(category == "Daily" or category == "Weekly", `AssignQuests: category must be "Daily" or "Weekly"`)
		assert(typeof(resetId) == "string", "AssignQuests: resetId must be a string")
		assert(typeof(ids) == "table", "AssignQuests: ids must be a table")

		local active = {}
		for _, id in ids do
			table.insert(active, { id = id, progress = 0, claimed = false })
		end

		playerData.quests[category] = { resetId = resetId, active = active }

	elseif action.type == "SetQuestProgress" then
		local category = action.data.category
		local id = action.data.id
		local progress = action.data.progress

		assert(category == "Daily" or category == "Weekly", `SetQuestProgress: category must be "Daily" or "Weekly"`)
		assert(typeof(id) == "string", "SetQuestProgress: id must be a string")
		assert(typeof(progress) == "number", "SetQuestProgress: progress must be a number")

		for _, quest in playerData.quests[category].active do
			if quest.id == id then
				quest.progress = progress
				break
			end
		end

	elseif action.type == "ClaimQuest" then
		local category = action.data.category
		local id = action.data.id

		assert(category == "Daily" or category == "Weekly", `ClaimQuest: category must be "Daily" or "Weekly"`)
		assert(typeof(id) == "string", "ClaimQuest: id must be a string")

		for _, quest in playerData.quests[category].active do
			if quest.id == id then
				assert(not quest.claimed, `ClaimQuest: quest "{id}" already claimed`)
				quest.claimed = true
				break
			end
		end

	elseif action.type == "CompleteTutorial" then
		playerData.tutorial.completed = true

	elseif action.type == "SetLastWinDate" then
		local date = action.data.date
		assert(typeof(date) == "string", "SetLastWinDate: date must be a string")

		playerData.profile.lastWinDate = date

	else
		warn("[UpdateData] Unknown action type:", action.type)
	end
end