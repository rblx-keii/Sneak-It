--[[
	DevProducts.lua
	Sub-module of Monetization.

	Handles consumable DevProduct purchases. Acts as the catch-all receipt
	processor for any productId not claimed by another sub-module.

	Implements pending receipt safety: the receipt is written to PendingReceipts
	before the award channel is invoked, and cleared only after a confirmed grant.
	If the award channel times out or returns false, the receipt stays pending and
	Roblox retries via ProcessReceipt on the next server.

	Award channel: Config.Channels.DevProduct
	Handler signature: (player: Player, productId: number) -> boolean
--]]

--|| References
local Config       = require(script.Parent.Config)
local AwardChannel = require(script.Parent.AwardChannel)

--|| Types
type PurchaseProfile = any
type MonetizationContext = any

--|| MAIN ||--
local Local = {}
local Shared = {}

--|| Variables
local _context: MonetizationContext = nil
local _sessionGranted: { [string]: boolean } = nil

-- [[ Startup ]] --
function Shared.Init(context: MonetizationContext)
	_context = context
	_sessionGranted = context.SessionGranted
end

function Shared.Start() end

-- [[ Private Functions ]] --

function Local.AwardPlayer(player: Player, productId: number, purchaseId: string, data: any): boolean
	-- Invoke the award channel — waits up to AwardTimeoutSeconds for a handler
	local granted = AwardChannel.Invoke(Config.Channels.DevProduct, player, productId)

	if not granted then
		-- Leave PendingReceipts entry intact so next session can retry
		warn(`[Monetization.DevProducts] Award channel returned false or timed out for productId {productId} ({player.Name})`)
		return false
	end

	_sessionGranted[purchaseId] = true
	data.PendingReceipts[purchaseId] = nil
	return true
end

-- [[ Public Functions ]] --

--- DevProducts never claims ownership — it is the catch-all fallback.
function Shared.ClaimsProduct(_productId: number): boolean
	return false
end

function Shared.ProcessReceipt(receiptInfo: any, data: any): Enum.ProductPurchaseDecision
	local purchaseId = tostring(receiptInfo.PurchaseId)
	local productId  = receiptInfo.ProductId
	local userId     = receiptInfo.PlayerId

	if _sessionGranted[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local Players = game:GetService("Players")
	local player  = Players:GetPlayerByUserId(userId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Write pending receipt before invoking — crash-safe
	data.PendingReceipts[purchaseId] = productId

	if Local.AwardPlayer(player, productId, purchaseId, data) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

--- Replay any receipts that were pending when the server last shut down.
function Shared.OnPlayerAdded(player: Player, data: any)
	for purchaseId, productId in pairs(data.PendingReceipts) do
		Local.AwardPlayer(player, productId, purchaseId, data)
	end
end

function Shared.OnPlayerRemoving(_player: Player) end

return Shared