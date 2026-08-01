--[[
	Monetization / init.lua
	Main module. Exposes the unified monetization API.

	ProfileStore session management lives here (inline). Sub-modules are all
	optional — deleting any one of them will produce a warning but will not
	break the package. Each loaded sub-module receives a shared context table
	so it can read profile data and fire signals without coupling directly to
	this module.

	Sub-modules follow this optional interface:
	    SubModule.Init(context: MonetizationContext)
	    SubModule.Start()
	    SubModule.OnPlayerAdded(player, data)
	    SubModule.OnPlayerRemoving(player)
	    SubModule.ClaimsProduct(productId) -> boolean
	    SubModule.ProcessReceipt(receiptInfo, data) -> Enum.ProductPurchaseDecision

	ProcessReceipt routing: sub-modules are checked in declaration order via
	ClaimsProduct. DevProducts is always the catch-all fallback and never claims.
--]]

--|| Services
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

--|| References
local Signal = require(script.Packages.Signal)
local ProfileStore = require(script.Parent.Parent.Packages.ProfileStore)
local Config = require(script.Config)
local Channel = require(script.Packages.Channel)

--|| Types
type PurchaseProfile = {
	-- DevProducts
	PendingReceipts: { [string]: number },
	-- Bundles
	GrantedBundles: { [string]: boolean },
	-- Gamepasses
	OwnedGamepasses: { [string]: boolean },
	-- Subscriptions
	OwnedSubscriptions: { [string]: boolean },
	-- Gifting
	GiftedGamepasses: { [string]: boolean },
	GiftedSubscriptions: { [string]: number }, -- subId -> expiry unix timestamp
	PendingGifts: { [string]: any },            -- pending direct gifts awaiting delivery
}

type MonetizationContext = {
	GetProfileData: (player: Player) -> PurchaseProfile?,
	Purchased: any,    -- Signal
	StockUpdated: any, -- Signal
	SessionGranted: { [string]: boolean },
}

--|| Constants
local PROFILE_TEMPLATE: PurchaseProfile = {
	PendingReceipts = {},
	GrantedBundles = {},
	OwnedGamepasses = {},
	OwnedSubscriptions = {},
	GiftedGamepasses = {},
	GiftedSubscriptions = {},
	PendingGifts = {},
}

local SUB_MODULE_NAMES = {
	"DevProducts",
	"Gamepasses",
	"Bundles",
	"Subscriptions",
	"GiftPurchasing",
}

--|| ProfileStore
local PurchaseProfiles = ProfileStore.New(Config.ProfileStoreKey, PROFILE_TEMPLATE)

--|| MAIN ||--
local Local = {}
local Shared = {}

--|| Variables
local _profiles: { [number]: any } = {}
local _sessionGranted: { [string]: boolean } = {}
local _subModules: { [string]: any } = {}

-- [[ Signals ]] --
Shared.Purchased = Signal.new()
Shared.StockUpdated = Signal.new()

-- [[ Startup ]] --
function Shared.Init()
	-- Build the shared context passed to every sub-module
	local context: MonetizationContext = {
		GetProfileData = Local.GetProfileData,
		Purchased = Shared.Purchased,
		StockUpdated = Shared.StockUpdated,
		SessionGranted = _sessionGranted,
	}

	-- Attempt to load each optional sub-module
	for _, name in ipairs(SUB_MODULE_NAMES) do
		local child = script:FindFirstChild(name)
		if not child then
			warn("[Monetization] Optional sub-module not found, skipping:", name)
			continue
		end

		local ok, mod = pcall(require, child)
		if not ok then
			warn("[Monetization] Failed to require sub-module:", name, "-", tostring(mod))
			continue
		end

		_subModules[name] = mod

		if type(mod.Init) == "function" then
			local initOk, initErr = pcall(mod.Init, context)
			if not initOk then
				warn("[Monetization] Sub-module Init error:", name, "-", tostring(initErr))
			end
		end
	end

	-- Hook Marketplace callbacks
	MarketplaceService.ProcessReceipt = Local.ProcessReceipt

	if _subModules.Gamepasses then
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
			_subModules.Gamepasses.OnGamepassPurchased(player, passId, wasPurchased)
		end)
	end

	-- BindToClose: end all active sessions cleanly
	game:BindToClose(function()
		for _, player in ipairs(Players:GetPlayers()) do
			Local.ReleaseProfile(player)
		end
	end)
end

function Shared.Start()
	-- Start each sub-module
	for name, mod in pairs(_subModules) do
		if type(mod.Start) == "function" then
			local ok, err = pcall(mod.Start)
			if not ok then
				warn("[Monetization] Sub-module Start error:", name, "-", tostring(err))
			end
		end
	end

	Players.PlayerAdded:Connect(Local.OnPlayerAdded)
	Players.PlayerRemoving:Connect(Local.OnPlayerRemoving)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(Local.OnPlayerAdded, player)
	end
end

-- [[ Private Functions ]] --

--- Returns the profile data table for a player, or nil if not loaded.
function Local.GetProfileData(player: Player): PurchaseProfile?
	local profile = _profiles[player.UserId]
	return profile and profile.Data or nil
end

function Local.ReleaseProfile(player: Player)
	local profile = _profiles[player.UserId]
	if profile then
		profile:EndSession()
		_profiles[player.UserId] = nil
	end
end

function Local.OnPlayerAdded(player: Player)
	local profile = PurchaseProfiles:StartSessionAsync("Player_" .. player.UserId, {
		Cancel = function()
			return player.Parent == nil
		end,
	})

	if not profile then
		player:Kick("Failed to load your purchase data. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		_profiles[player.UserId] = nil
		if player.Parent then
			player:Kick("Your session ended unexpectedly. Please rejoin.")
		end
	end)

	if not player.Parent then
		profile:EndSession()
		return
	end

	_profiles[player.UserId] = profile
	local data: PurchaseProfile = profile.Data

	-- Notify each sub-module
	for name, mod in pairs(_subModules) do
		if type(mod.OnPlayerAdded) == "function" then
			local ok, err = pcall(mod.OnPlayerAdded, player, data)
			if not ok then
				warn("[Monetization] OnPlayerAdded error in sub-module:", name, "-", tostring(err))
			end
		end
	end
end

function Local.OnPlayerRemoving(player: Player)
	for name, mod in pairs(_subModules) do
		if type(mod.OnPlayerRemoving) == "function" then
			local ok, err = pcall(mod.OnPlayerRemoving, player)
			if not ok then
				warn("[Monetization] OnPlayerRemoving error in sub-module:", name, "-", tostring(err))
			end
		end
	end

	Local.ReleaseProfile(player)
end

--- Routes a receipt to whichever sub-module claims it.
--- Sub-modules are checked in SUB_MODULE_NAMES order via ClaimsProduct.
--- DevProducts (last, catch-all) returns false from ClaimsProduct so it is
--- always the final fallback.
function Local.ProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local productId = receiptInfo.ProductId
	local userId = receiptInfo.PlayerId
	local purchaseId = tostring(receiptInfo.PurchaseId)

	if _sessionGranted[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player = Players:GetPlayerByUserId(userId)
	local data = player and Local.GetProfileData(player)

	if not player or not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Find the first sub-module that claims this product
	local handler = nil
	for _, name in ipairs(SUB_MODULE_NAMES) do
		local mod = _subModules[name]
		if not mod then continue end

		if type(mod.ClaimsProduct) == "function" and mod.ClaimsProduct(productId) then
			handler = mod
			break
		end
	end

	-- Fall back to DevProducts if no one claimed it
	if not handler then
		handler = _subModules.DevProducts
	end

	if not handler or type(handler.ProcessReceipt) ~= "function" then
		warn("[Monetization] No handler found for productId:", productId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local ok, result = pcall(handler.ProcessReceipt, receiptInfo, data)
	if not ok then
		warn("[Monetization] ProcessReceipt error for productId:", productId, "-", tostring(result))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	return result
end

-- [[ Public Functions ]] --

--- Returns true if the player has purchased or been granted the given bundle.
function Shared.PlayerOwnsBundle(player: Player, productId: number): boolean
	if not _subModules.Bundles then return false end
	return _subModules.Bundles.PlayerOwnsBundle(player, productId)
end

--- Returns true if the player owns the given gamepass (native or cached).
function Shared.PlayerOwnsGamepass(player: Player, passId: number): boolean
	if not _subModules.Gamepasses then return false end
	return _subModules.Gamepasses.PlayerOwnsGamepass(player, passId)
end

--- Returns true if the player has an active native subscription.
function Shared.PlayerOwnsSubscription(player: Player, subId: string): boolean
	if not _subModules.Subscriptions then return false end
	return _subModules.Subscriptions.PlayerOwnsSubscription(player, subId)
end

--- Returns true if the player was gifted the given gamepass.
function Shared.PlayerHasGiftedGamepass(player: Player, passId: number): boolean
	if not _subModules.GiftPurchasing then return false end
	return _subModules.GiftPurchasing.PlayerHasGiftedGamepass(player, passId)
end

--- Returns true if the player has an active gifted subscription (not yet expired).
function Shared.PlayerHasActiveGiftedSubscription(player: Player, subId: string): boolean
	if not _subModules.GiftPurchasing then return false end
	return _subModules.GiftPurchasing.PlayerHasActiveGiftedSubscription(player, subId)
end

--- Returns the current live stock for a limited bundle, or nil for unlimited.
function Shared.GetLiveStock(productId: number): number?
	if not _subModules.Bundles then return nil end
	return _subModules.Bundles.GetLiveStock(productId)
end

--- Attempts to redeem a gift code for a player.
--- Returns (success: boolean, message: string) — surface the message to the player.
function Shared.RedeemGiftCode(player: Player, code: string): (boolean, string)
	if not _subModules.GiftPurchasing then
		return false, "Gift purchasing is not enabled."
	end
	return _subModules.GiftPurchasing.RedeemCode(player, code)
end

-- Expose Channel and Config so external services need only require Monetization
Shared.Channel = Channel
Shared.Config  = Config

return Shared