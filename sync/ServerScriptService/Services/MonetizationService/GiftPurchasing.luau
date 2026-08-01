--[[
	GiftPurchasing.lua
	Sub-module of Monetization.

	Handles gifting of Gamepasses and pseudo-Subscriptions (timed perks) via two
	DevProduct purchase paths:

	  1. Direct Gift  — buyer picks a target player. Delivered instantly if online,
	                    attempted cross-server via MessagingService, and queued in
	                    the recipient's profile for next-join fallback.

	  2. Code Gift    — buyer receives a XXXX-XXXX-XXXX redeemable code to share
	                    freely (contests, raffles, giveaways). Codes are cached
	                    in memory and backed up to DataStore every 5 minutes via
	                    a distributed save lock.

	Award channels used:
	    Config.Channels.GiftedGamepass      — when a gifted gamepass is applied
	    Config.Channels.GiftedSubscription  — when a gifted subscription is applied
	    Config.Channels.GiftCode            — when a code is generated (buyer notified)
	    Config.Channels.DirectGiftSent      — when a direct gift is dispatched (buyer notified)

	All handler signatures: (player: Player, productId: number | string, meta: any?) -> boolean
--]]

--|| Services
local DataStoreService  = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService  = game:GetService("MessagingService")
local Players           = game:GetService("Players")

--|| References
local Config       = require(script.Parent.Config)
local AwardChannel = require(script.Parent.AwardChannel)

--|| Types
export type GiftType = "Gamepass" | "Subscription"

export type GiftDefinition = {
	giftType: GiftType,
	grantValue: number | string,
	durationDays: number?,
}

export type GiftCodeRecord = {
	code: string,
	giftKey: string,
	expiry: number?,
	redeemedBy: number?,
	createdAt: number,
}

export type GiftRecord = {
	giftKey: string,
	giverUserId: number,
	createdAt: number,
}

type PurchaseProfile = any
type MonetizationContext = any

--|| Constants
local CODE_CHARSET        = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local CODE_SEGMENT_LENGTH = 4
local CODE_SEGMENT_COUNT  = 3
local CODE_EXPIRY_DAYS    = Config.GiftCodeExpiryDays or 30

local SAVE_INTERVAL      = 300
local SAVE_LOOP_INTERVAL = 60
local SAVE_LOCK_EXPIRY   = 600
local JITTER_MAX         = 10
local MSG_TOPIC          = "GiftDelivery_v1"

local GIFT_PRODUCT_IDS: {
	[string]: {
		directProductId: number,
		codeProductId: number,
		definition: GiftDefinition,
	}
} = Config.GiftProductIds or {}

--|| Stores
local GiftCodeStore   = DataStoreService:GetDataStore("GiftCodes_v1")
local GiftSaveLockMap = MemoryStoreService:GetSortedMap("GiftCodeSaveLocks_v1")

--|| MAIN ||--
local Local = {}
local Shared = {}

--|| Variables
local _context: MonetizationContext = nil
local _codeCache: { [string]: GiftCodeRecord } = {}
local _productRoutes: { [number]: { giftKey: string, flow: "direct" | "code" } } = {}

-- [[ Startup ]] --
function Shared.Init(context: MonetizationContext)
	_context = context

	for giftKey, entry in pairs(GIFT_PRODUCT_IDS) do
		_productRoutes[entry.directProductId] = { giftKey = giftKey, flow = "direct" }
		_productRoutes[entry.codeProductId]   = { giftKey = giftKey, flow = "code" }
	end

	Local.LoadCodesFromStore()

	pcall(function()
		MessagingService:SubscribeAsync(MSG_TOPIC, function(message)
			Local.OnGiftDeliveryMessage(message.Data)
		end)
	end)
end

function Shared.Start()
	task.spawn(function()
		task.wait(math.random(1, JITTER_MAX))

		while task.wait(SAVE_LOOP_INTERVAL) do
			local canSave = false

			pcall(function()
				GiftSaveLockMap:UpdateAsync("CodeCache_LastSave", function(last)
					local now = os.time()
					if not last or (now - last) >= SAVE_INTERVAL then
						canSave = true
						return now
					end
					return nil
				end, SAVE_LOCK_EXPIRY)
			end)

			if canSave then
				Local.SaveCacheToStore()
			end
		end
	end)
end

-- [[ Private Functions ]] --

function Local.LoadCodesFromStore()
	local ok, stored = pcall(function()
		return GiftCodeStore:GetAsync("AllCodes")
	end)
	if ok and stored and type(stored) == "table" then
		_codeCache = stored
	end
end

function Local.SaveCacheToStore()
	pcall(function()
		GiftCodeStore:SetAsync("AllCodes", _codeCache)
	end)
end

function Local.GenerateCode(): string
	local segments = {}
	for _ = 1, CODE_SEGMENT_COUNT do
		local seg = {}
		for _ = 1, CODE_SEGMENT_LENGTH do
			local idx = math.random(1, #CODE_CHARSET)
			table.insert(seg, CODE_CHARSET:sub(idx, idx))
		end
		table.insert(segments, table.concat(seg))
	end
	return table.concat(segments, "-")
end

function Local.CreateUniqueCode(): string
	local code
	local attempts = 0
	repeat
		code = Local.GenerateCode()
		attempts += 1
		if attempts > 50 then
			warn("[Monetization.GiftPurchasing] Could not generate a unique code after 50 attempts.")
			break
		end
	until not _codeCache[code]
	return code
end

function Local.ApplyGiftToProfile(
	player: Player,
	data: any,
	definition: GiftDefinition,
	giverUserId: number
)
	local meta = { giverUserId = giverUserId }

	if definition.giftType == "Gamepass" then
		local passId = tostring(definition.grantValue)
		data.GiftedGamepasses[passId] = true

		local granted = AwardChannel.Invoke(Config.Channels.GiftedGamepass, player, definition.grantValue, meta)
		if not granted then
			warn(`[Monetization.GiftPurchasing] GiftedGamepass channel timed out for passId {passId} ({player.Name})`)
		end

	elseif definition.giftType == "Subscription" then
		local subId      = tostring(definition.grantValue)
		local duration   = (definition.durationDays or 30) * 86400
		local expiry     = os.time() + duration
		local current    = data.GiftedSubscriptions[subId] or 0

		data.GiftedSubscriptions[subId] = math.max(current, expiry)
		meta.expiry = data.GiftedSubscriptions[subId]

		local granted = AwardChannel.Invoke(Config.Channels.GiftedSubscription, player, definition.grantValue, meta)
		if not granted then
			warn(`[Monetization.GiftPurchasing] GiftedSubscription channel timed out for subId {subId} ({player.Name})`)
		end
	end
end

function Local.TryDeliverLocally(recipientUserId: number, giftRecord: GiftRecord): boolean
	local player = Players:GetPlayerByUserId(recipientUserId)
	if not player then return false end

	local data = _context.GetProfileData(player)
	if not data then return false end

	local entry = GIFT_PRODUCT_IDS[giftRecord.giftKey]
	if not entry then return false end

	local key = giftRecord.giftKey .. "_" .. tostring(giftRecord.giverUserId)
	data.PendingGifts[key] = nil

	Local.ApplyGiftToProfile(player, data, entry.definition, giftRecord.giverUserId)
	return true
end

function Local.OnGiftDeliveryMessage(data: any)
	if type(data) ~= "table" then return end
	Local.TryDeliverLocally(data.recipientUserId, data.giftRecord)
end

function Local.QueueGiftForRecipient(recipientUserId: number, giftRecord: GiftRecord)
	local player = Players:GetPlayerByUserId(recipientUserId)
	local data   = player and _context.GetProfileData(player)
	if not data then return end

	local key = giftRecord.giftKey .. "_" .. tostring(giftRecord.giverUserId)
	data.PendingGifts[key] = giftRecord
end

-- [[ Public Functions ]] --

function Shared.ClaimsProduct(productId: number): boolean
	return _productRoutes[productId] ~= nil
end

function Shared.ProcessReceipt(receiptInfo: any, data: PurchaseProfile): Enum.ProductPurchaseDecision
	local purchaseId = tostring(receiptInfo.PurchaseId)
	local productId  = receiptInfo.ProductId
	local userId     = receiptInfo.PlayerId

	if _context.SessionGranted[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local route = _productRoutes[productId]
	if not route then return Enum.ProductPurchaseDecision.NotProcessedYet end

	local player = Players:GetPlayerByUserId(userId)
	if not player then return Enum.ProductPurchaseDecision.NotProcessedYet end

	local entry = GIFT_PRODUCT_IDS[route.giftKey]
	if not entry then return Enum.ProductPurchaseDecision.NotProcessedYet end

	-- [[ Code Flow ]] --
	if route.flow == "code" then
		local code   = Local.CreateUniqueCode()
		local expiry = os.time() + CODE_EXPIRY_DAYS * 86400

		_codeCache[code] = {
			code      = code,
			giftKey   = route.giftKey,
			expiry    = expiry,
			redeemedBy = nil,
			createdAt = os.time(),
		}

		-- Notify the buyer — reward service surfaces the code in UI
		local granted = AwardChannel.Invoke(Config.Channels.GiftCode, player, productId, {
			code    = code,
			giftKey = route.giftKey,
			expiry  = expiry,
		})

		if not granted then
			warn(`[Monetization.GiftPurchasing] GiftCode channel timed out for {player.Name}. Code: {code}`)
			-- Code was written to cache; don't return NotProcessedYet or Roblox
			-- will re-fire the receipt and generate a second code. Grant anyway.
		end

		_context.SessionGranted[purchaseId] = true
		return Enum.ProductPurchaseDecision.PurchaseGranted

		-- [[ Direct Gift Flow ]] --
	elseif route.flow == "direct" then
		local recipientUserId = receiptInfo.Metadata
			and type(receiptInfo.Metadata) == "table"
			and receiptInfo.Metadata.recipientUserId

		if not recipientUserId or type(recipientUserId) ~= "number" then
			warn("[Monetization.GiftPurchasing] Direct gift missing recipientUserId in receipt metadata.")
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		if recipientUserId == userId then
			warn("[Monetization.GiftPurchasing]", player.Name, "tried to gift themselves.")
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local giftRecord: GiftRecord = {
			giftKey      = route.giftKey,
			giverUserId  = userId,
			createdAt    = os.time(),
		}

		-- 1. Try local delivery
		Local.TryDeliverLocally(recipientUserId, giftRecord)

		-- 2. Broadcast cross-server
		pcall(function()
			MessagingService:PublishAsync(MSG_TOPIC, {
				recipientUserId = recipientUserId,
				giftRecord      = giftRecord,
			})
		end)

		-- 3. Queue in profile for next-join fallback
		Local.QueueGiftForRecipient(recipientUserId, giftRecord)

		-- Notify the buyer
		AwardChannel.Invoke(Config.Channels.DirectGiftSent, player, productId, {
			recipientUserId = recipientUserId,
			giftKey         = route.giftKey,
		})

		_context.SessionGranted[purchaseId] = true
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

--- Deliver any queued gifts on player join.
function Shared.OnPlayerAdded(player: Player, data: PurchaseProfile)
	for key, giftRecord in pairs(data.PendingGifts) do
		local entry = GIFT_PRODUCT_IDS[giftRecord.giftKey]
		if not entry then
			data.PendingGifts[key] = nil
			continue
		end
		Local.ApplyGiftToProfile(player, data, entry.definition, giftRecord.giverUserId)
		data.PendingGifts[key] = nil
	end

	-- Re-notify for active gifted subscriptions
	for subId, expiry in pairs(data.GiftedSubscriptions) do
		if os.time() < expiry then
			AwardChannel.Invoke(Config.Channels.GiftedSubscription, player, subId, {
				expiry = expiry,
			})
		else
			data.GiftedSubscriptions[subId] = nil
		end
	end

	-- Re-notify for gifted gamepasses
	for passId in pairs(data.GiftedGamepasses) do
		AwardChannel.Invoke(Config.Channels.GiftedGamepass, player, tonumber(passId), {})
	end
end

--- Attempt to redeem a gift code for a player.
--- Returns (success: boolean, message: string)
function Shared.RedeemCode(player: Player, rawCode: string): (boolean, string)
	local code   = rawCode:upper():gsub("%s+", "")
	local record = _codeCache[code]

	if not record then
		return false, "Code not found."
	end
	if record.redeemedBy then
		return false, "This code has already been redeemed."
	end
	if record.expiry and os.time() > record.expiry then
		return false, "This code has expired."
	end

	local data = _context.GetProfileData(player)
	if not data then
		return false, "Could not load your profile. Please try again."
	end

	local entry = GIFT_PRODUCT_IDS[record.giftKey]
	if not entry then
		return false, "Invalid gift type."
	end

	-- Mark redeemed before applying (prevents double-redeem on crash)
	record.redeemedBy = player.UserId
	_codeCache[code] = record

	Local.ApplyGiftToProfile(player, data, entry.definition, 0)

	return true, "Gift successfully redeemed!"
end

function Shared.PlayerHasGiftedGamepass(player: Player, passId: number): boolean
	local data = _context.GetProfileData(player)
	if not data then return false end
	return data.GiftedGamepasses[tostring(passId)] == true
end

function Shared.PlayerHasActiveGiftedSubscription(player: Player, subId: string): boolean
	local data = _context.GetProfileData(player)
	if not data then return false end
	local expiry = data.GiftedSubscriptions[subId]
	return expiry ~= nil and os.time() < expiry
end

function Shared.OnPlayerRemoving(_player: Player) end

return Shared