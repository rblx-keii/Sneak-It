--[[
	Bundles.lua
	Sub-module of Monetization.

	Handles limited-stock one-time DevProduct bundles. Stock is tracked live in
	MemoryStore and backed up to DataStore every 5 minutes via a distributed save
	lock. Stock drops are broadcast cross-server via MessagingService.

	Award channel: Config.Channels.Bundle
	Handler signature: (player: Player, productId: number, bundleDef: BundleDef) -> boolean
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
type RewardItem = { itemId: string, quantity: number? }

type BundleRewards = {
	coins: number?,
	spins: number?,
	winStreakProtection: number?,
	items: { RewardItem }?,
	custom: { [string]: any }?,
}

export type BundleDef = {
	ProductId: number,
	Name: string,
	MaxStock: number?,
	Rewards: BundleRewards,
	OnAwarded: ((player: Player, rewards: BundleRewards) -> ())?,
}

type PurchaseProfile = any
type MonetizationContext = any

--|| Constants
local BUNDLES_FOLDER     = Config.BundlesFolder
local MEMORY_STORE_EXPIRY = 2592000 -- 30 days
local SAVE_LOCK_EXPIRY   = 600
local SAVE_INTERVAL      = 300
local SAVE_LOOP_INTERVAL = 60
local JITTER_MAX         = 10

--|| Stores
local BundleStockStore = DataStoreService:GetDataStore("BundleStock_ColdStorage_v1")
local BundleStockMap   = MemoryStoreService:GetSortedMap("BundleStock_Live_v1")
local SaveLockMap      = MemoryStoreService:GetSortedMap("BundleSaveLocks_v1")

--|| MAIN ||--
local Local = {}
local Shared = {}

--|| Variables
local _context: MonetizationContext = nil
local _bundleMap: { [number]: BundleDef } = {}
local _liveStocks: { [number]: number } = {}

-- [[ Startup ]] --
function Shared.Init(context: MonetizationContext)
	_context = context
	Local.LoadBundles()

	for productId, def in pairs(_bundleMap) do
		if not def.MaxStock then continue end

		local dsOk, dsStock = pcall(function()
			return BundleStockStore:GetAsync(tostring(productId))
		end)

		local startingStock = (dsOk and dsStock ~= nil) and dsStock or def.MaxStock

		local memOk, currentStock = pcall(function()
			return BundleStockMap:UpdateAsync(tostring(productId), function(memVal)
				return memVal or startingStock
			end, MEMORY_STORE_EXPIRY)
		end)

		_liveStocks[productId] = (memOk and currentStock) or startingStock
	end

	pcall(function()
		MessagingService:SubscribeAsync("BundleStockDrop", function(message)
			local data = message.Data
			_liveStocks[data.id] = data.remaining
			_context.StockUpdated:Fire(data.id, data.remaining)
		end)
	end)
end

function Shared.Start()
	task.spawn(function()
		task.wait(math.random(1, JITTER_MAX))

		while task.wait(SAVE_LOOP_INTERVAL) do
			for productId, def in pairs(_bundleMap) do
				if not def.MaxStock then continue end

				local canSave = false
				local lockKey = tostring(productId) .. "_LastSave"

				pcall(function()
					SaveLockMap:UpdateAsync(lockKey, function(lastSavedTime)
						local now = os.time()
						if not lastSavedTime or (now - lastSavedTime) >= SAVE_INTERVAL then
							canSave = true
							return now
						end
						return nil
					end, SAVE_LOCK_EXPIRY)
				end)

				if canSave then
					local memOk, liveStock = pcall(function()
						return BundleStockMap:GetAsync(tostring(productId))
					end)
					if memOk and liveStock ~= nil then
						pcall(function()
							BundleStockStore:SetAsync(tostring(productId), liveStock)
						end)
					end
				end
			end
		end
	end)
end

-- [[ Private Functions ]] --

function Local.LoadBundles()
	if not BUNDLES_FOLDER then
		warn("[Monetization.Bundles] Config.BundlesFolder is nil — no bundles loaded.")
		return
	end

	for _, moduleScript in ipairs(BUNDLES_FOLDER:GetChildren()) do
		if not moduleScript:IsA("ModuleScript") then continue end
		if moduleScript.Name == "Template" then continue end

		local ok, def = pcall(require, moduleScript)
		if ok and def and def.ProductId then
			_bundleMap[def.ProductId] = def
		else
			warn("[Monetization.Bundles] Failed to load bundle module:", moduleScript.Name)
		end
	end
end

function Local.TryClaimStock(productId: number, bundleDef: BundleDef): boolean
	if not bundleDef.MaxStock then return true end

	local claimed = false
	local updatedStock = 0

	local ok = pcall(function()
		BundleStockMap:UpdateAsync(tostring(productId), function(current)
			current = current or bundleDef.MaxStock
			if current > 0 then
				claimed = true
				updatedStock = current - 1
				return updatedStock
			end
			return nil
		end, MEMORY_STORE_EXPIRY)
	end)

	if ok and claimed then
		_liveStocks[productId] = updatedStock
		_context.StockUpdated:Fire(productId, updatedStock)

		pcall(function()
			MessagingService:PublishAsync("BundleStockDrop", {
				id = productId,
				remaining = updatedStock,
			})
		end)

		return true
	end

	return false
end

function Local.AwardBundle(
	player: Player,
	productId: number,
	purchaseId: string,
	data: PurchaseProfile,
	bundleDef: BundleDef
): boolean
	-- Mark as granted in profile first (idempotency guard)
	data.GrantedBundles[tostring(productId)] = true

	-- Fire optional OnAwarded callback defined in the BundleDef itself
	if bundleDef.OnAwarded then
		pcall(bundleDef.OnAwarded, player, bundleDef.Rewards)
	end

	-- Invoke the award channel — reward service applies any additional perks
	local granted = AwardChannel.Invoke(Config.Channels.Bundle, player, productId, bundleDef)

	if not granted then
		warn(`[Monetization.Bundles] Award channel returned false or timed out for bundle {bundleDef.Name} ({player.Name})`)
		-- Profile is still marked granted to prevent double stock deduction on retry;
		-- the channel timeout means the reward may need manual follow-up.
		-- Return true here so Roblox doesn't retry and deduct stock again.
	end

	_context.SessionGranted[purchaseId] = true
	return true
end

-- [[ Public Functions ]] --

function Shared.ClaimsProduct(productId: number): boolean
	return _bundleMap[productId] ~= nil
end

function Shared.ProcessReceipt(receiptInfo: any, data: PurchaseProfile): Enum.ProductPurchaseDecision
	local purchaseId = tostring(receiptInfo.PurchaseId)
	local productId  = receiptInfo.ProductId
	local userId     = receiptInfo.PlayerId

	if _context.SessionGranted[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Idempotent re-grant (profile already marked, stock already claimed)
	if data.GrantedBundles[tostring(productId)] then
		_context.SessionGranted[purchaseId] = true
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local bundleDef = _bundleMap[productId]

	if not Local.TryClaimStock(productId, bundleDef) then
		warn(`[Monetization.Bundles] {player.Name} tried to buy {bundleDef.Name} but it sold out mid-purchase.`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if Local.AwardBundle(player, productId, purchaseId, data, bundleDef) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function Shared.GetLiveStock(productId: number): number?
	local bundle = _bundleMap[productId]
	if not bundle or not bundle.MaxStock then return nil end
	return _liveStocks[productId] or bundle.MaxStock
end

function Shared.PlayerOwnsBundle(player: Player, productId: number): boolean
	local data = _context.GetProfileData(player)
	if not data then return false end
	return data.GrantedBundles[tostring(productId)] == true
end

function Shared.OnPlayerAdded(_player: Player, _data: PurchaseProfile) end
function Shared.OnPlayerRemoving(_player: Player) end

return Shared