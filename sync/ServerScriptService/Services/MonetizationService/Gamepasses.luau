--[[
	Gamepasses.lua
	Sub-module of Monetization.

	Handles permanent one-time Roblox Gamepass purchases. On player join, checks
	the profile cache first to avoid repeated API calls, falling back to
	UserOwnsGamePassAsync once per pass if not cached.

	Award channel: Config.Channels.Gamepass
	Handler signature: (player: Player, passId: number) -> boolean
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
local GAMEPASS_IDS: { [number]: boolean } = Config.GamepassIds

--|| MAIN ||--
local Local = {}
local Shared = {}

--|| Variables
local _context: MonetizationContext = nil

-- [[ Startup ]] --
function Shared.Init(context: MonetizationContext)
	_context = context
end

function Shared.Start() end

-- [[ Private Functions ]] --

function Local.GrantPass(player: Player, data: PurchaseProfile, passId: number)
	if not data.OwnedGamepasses[tostring(passId)] then
		data.OwnedGamepasses[tostring(passId)] = true
	end

	-- Notify via channel — reward service applies perks
	local granted = AwardChannel.Invoke(Config.Channels.Gamepass, player, passId)
	if not granted then
		warn(`[Monetization.Gamepasses] Award channel returned false or timed out for passId {passId} ({player.Name})`)
	end
end

-- [[ Public Functions ]] --

function Shared.OnPlayerAdded(player: Player, data: PurchaseProfile)
	for passId in pairs(GAMEPASS_IDS) do
		if data.OwnedGamepasses[tostring(passId)] then
			AwardChannel.Invoke(Config.Channels.Gamepass, player, passId)
			continue
		end

		local ok, owns = pcall(
			MarketplaceService.UserOwnsGamePassAsync,
			MarketplaceService,
			player.UserId,
			passId
		)

		if ok and owns then
			Local.GrantPass(player, data, passId)
		end
	end
end

function Shared.OnGamepassPurchased(player: Player, passId: number, wasPurchased: boolean)
	if not wasPurchased then return end
	if not GAMEPASS_IDS[passId] then return end

	local data = _context.GetProfileData(player)
	if not data then return end

	Local.GrantPass(player, data, passId)
end

function Shared.PlayerOwnsGamepass(player: Player, passId: number): boolean
	local data = _context.GetProfileData(player)
	if not data then return false end
	return data.OwnedGamepasses[tostring(passId)] == true
end

function Shared.OnPlayerRemoving(_player: Player) end

return Shared