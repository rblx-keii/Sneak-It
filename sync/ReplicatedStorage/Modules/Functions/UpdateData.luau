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
		local itemName = action.data.itemName

		if itemName == nil then
			playerData.loadout = nil
			return
		end

		assert(typeof(itemName) == "string" and itemName ~= "", "SetLoadout: itemName must be a non-empty string or nil")
		assert(playerData.ownedItems[itemName] == true, `SetLoadout: item "{itemName}" not owned`)

		playerData.loadout = itemName

	elseif action.type == "AddOwnedItem" then
		local itemName = action.data.itemName
		assert(typeof(itemName) == "string" and itemName ~= "", "AddOwnedItem: itemName must be a non-empty string")

		playerData.ownedItems[itemName] = true

	elseif action.type == "RemoveOwnedItem" then
		local itemName = action.data.itemName
		assert(typeof(itemName) == "string" and itemName ~= "", "RemoveOwnedItem: itemName must be a non-empty string")

		playerData.ownedItems[itemName] = nil

		if playerData.loadout == itemName then
			playerData.loadout = nil
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