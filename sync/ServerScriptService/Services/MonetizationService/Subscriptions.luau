--[[
	Subscriptions.lua
	Sub-module of Monetization.

	Handles native Roblox recurring subscriptions. On player join checks the
	profile cache first, then falls back to GetUserSubscriptionStatusAsync.
	Subscriptions that have lapsed are revoked from the cache.

	Award channel: Config.Channels.Subscription
	Handler signature: (player: Player, subId: string, active: boolean) -> boolean
	    active = true  → subscription is live, apply perks
	    active = false → subscription lapsed, remove perks
--]]

--|| Services
local MarketplaceService = game:GetService("MarketplaceService")

--|| References
local Config       = require(script.Parent.Config)
local AwardChannel = require(script.Parent.AwardChannel)

--|| Types
type PurchaseProfile = any
type MonetizationContext = any

--|| Constants
local SUBSCRIPTION_IDS: { [string]: boolean } = Config.SubscriptionIds

--|| MAIN ||--
local Local = {}
local Shared = {}

--|| Variables
local _context: MonetizationContext = nil
local _connections: { RBXScriptConnection } = {}

-- [[ Startup ]] --
function Shared.Init(context: MonetizationContext)
	_context = context
end

function Shared.Start()
	table.insert(
		_connections,
		MarketplaceService.PromptSubscriptionPurchaseFinished:Connect(Local.OnSubscriptionPurchaseFinished)
	)
end

-- [[ Private Functions ]] --

function Local.GrantSubscription(player: Player, data: PurchaseProfile, subId: string)
	data.OwnedSubscriptions[subId] = true

	local granted = AwardChannel.Invoke(Config.Channels.Subscription, player, subId, true)
	if not granted then
		warn(`[Monetization.Subscriptions] Award channel returned false or timed out for subId {subId} ({player.Name})`)
	end
end

function Local.RevokeSubscription(player: Player, data: PurchaseProfile, subId: string)
	data.OwnedSubscriptions[subId] = nil

	-- Notify with active = false so reward service removes perks
	AwardChannel.Invoke(Config.Channels.Subscription, player, subId, false)
end

function Local.OnSubscriptionPurchaseFinished(player: Player, subId: string, didSubscribe: boolean)
	if not SUBSCRIPTION_IDS[subId] then return end

	local data = _context.GetProfileData(player)
	if not data then return end

	if didSubscribe then
		Local.GrantSubscription(player, data, subId)
	end
end

-- [[ Public Functions ]] --

function Shared.OnPlayerAdded(player: Player, data: PurchaseProfile)
	for subId in pairs(SUBSCRIPTION_IDS) do
		local ok, status = pcall(
			MarketplaceService.GetUserSubscriptionStatusAsync,
			MarketplaceService,
			player,
			subId
		)

		if ok and status and status.IsSubscribed then
			Local.GrantSubscription(player, data, subId)
		elseif data.OwnedSubscriptions[subId] then
			-- Was cached as active but has since lapsed
			Local.RevokeSubscription(player, data, subId)
		end
	end
end

function Shared.PlayerOwnsSubscription(player: Player, subId: string): boolean
	local data = _context.GetProfileData(player)
	if not data then return false end
	return data.OwnedSubscriptions[subId] == true
end

function Shared.Destroy()
	for _, conn in _connections do conn:Disconnect() end
	table.clear(_connections)
end

function Shared.OnPlayerRemoving(_player: Player) end

return Shared