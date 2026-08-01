--[[
	Config.lua
	Monetization package configuration.

	This is the ONLY file you need to edit when dropping this package into a new
	project. Everything else reads from here.
--]]

local ServerStorage = game:GetService("ServerStorage")

return {
	--- The DataStore key prefix used for player purchase profiles.
	--- Change this if you need to reset all player data (e.g. a new season).
	ProfileStoreKey = "PlayerPurchaseLog_v3",

	--- Where your BundleDef ModuleScripts live.
	--- Each child must be a ModuleScript with a valid BundleDef shape.
	--- Set to nil to disable Bundles entirely (same effect as deleting Bundles.lua).
	BundlesFolder = ServerStorage:FindFirstChild("Bundles"),

	--- Gamepass IDs your game uses.
	--- Add every gamepass ID here. Removing an ID stops it being checked on join.
	GamepassIds = {
		-- [1785473168] = true,
		-- [1785663774] = true,
	},

	--- Subscription IDs your game uses (format: "EXP-XXXXXXXXXXXXXXXX").
	SubscriptionIds = {
		-- ["EXP-XXXXXXXXXXXXXXXX"] = true,
	},

	--- Gift product definitions.
	--- Each entry needs two DevProduct IDs: one for direct gifting, one for
	--- generating a redeemable code. See GiftPurchasing.lua for the full type.
	GiftProductIds = {
		-- BattlePass = {
		--     directProductId = 000000001,
		--     codeProductId   = 000000002,
		--     definition = {
		--         giftType     = "Subscription",
		--         grantValue   = "EXP-XXXXXXXXXXXXXXXX",
		--         durationDays = 30,
		--     },
		-- },
		-- VIPGamepass = {
		--     directProductId = 000000003,
		--     codeProductId   = 000000004,
		--     definition = {
		--         giftType   = "Gamepass",
		--         grantValue = 1785473168,
		--     },
		-- },
	},

	--- How many days a generated gift code is valid before it expires.
	GiftCodeExpiryDays = 30,

	--- Award channel names.
	--- Each purchase category has its own Channel. Your game's reward service
	--- registers a handler on each one it cares about. The monetization package
	--- invokes them on purchase and expects a boolean return:
	---     true  = reward delivered, mark as PurchaseGranted
	---     false = reward failed, mark as NotProcessedYet (Roblox will retry)
	---
	--- Handler signature for all categories:
	---   (player: Player, productId: number | string, meta: any?) -> boolean
	---
	--- Example (in your reward service Init):
	---   local Channel = require(Monetization.Packages.Channel)
	---   local Config  = require(Monetization.Config)
	---   Channel.Manager:SetHandler(Config.Channels.DevProduct, function(player, productId)
	---       Economy:AwardCoins(player, PRODUCT_REWARDS[productId])
	---       return true
	---   end)
	Channels = {
		DevProduct         = "Monetization.Award.DevProduct",
		Bundle             = "Monetization.Award.Bundle",
		Gamepass           = "Monetization.Award.Gamepass",
		Subscription       = "Monetization.Award.Subscription",
		GiftedGamepass     = "Monetization.Award.GiftedGamepass",
		GiftedSubscription = "Monetization.Award.GiftedSubscription",
		GiftCode           = "Monetization.Award.GiftCode",
		DirectGiftSent     = "Monetization.Award.DirectGiftSent",
	},

	--- How long (seconds) to wait for an Award channel handler before
	--- marking the purchase as NotProcessedYet so Roblox retries it.
	AwardTimeoutSeconds = 10,
}