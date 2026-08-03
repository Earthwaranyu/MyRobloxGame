local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Abilities = require(Shared.Abilities)
local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RarityOrder = require(Shared.RarityOrder)
local RemoteNames = require(Shared.RemoteNames)

local MonetizationService = require(script.Parent.MonetizationService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local TelemetryService = require(script.Parent.TelemetryService)

-- "Gacha can be open by points or robux (Open 1 time or 10 at a time)". Dash
-- is deliberately never in the pool (see Abilities.luau) -- everything
-- pulled here is a bonus on top of the one ability everyone already has for
-- free.
local GachaService = {}

GachaService.SINGLE_PULL_ROBUX_PRODUCT_ID = 3610626771
GachaService.TEN_PULL_ROBUX_PRODUCT_ID = 3610626811

-- 1500 points is also exactly the smallest points bundle (see
-- PointBundles.luau) -- buying it gets you exactly one pull's worth.
local SINGLE_PULL_POINTS_COST = 1500
local TEN_PULL_POINTS_COST = 13500 -- 10 for the price of 9

-- A pull landing on something already owned isn't a dead result -- it just
-- converts to a smaller one, same idea as a real gacha game's "shard/dupe"
-- consolation.
local DUPLICATE_REFUND_POINTS = 50

-- Pulls without a Mythic before the next one is guaranteed.
--
-- Shared with the client, which draws the pity bar against the same number --
-- see Constants.Gacha.MythicPityPulls for why it lives there and why it's 100.
local MYTHIC_PITY_PULLS = Constants.Gacha.MythicPityPulls

-- Every ability with a PullWeight is gacha-obtainable; built once since
-- Abilities never changes at runtime.
local pool: { Abilities.AbilityInfo } = {}
for _, info in Abilities do
	if info.PullWeight then
		table.insert(pool, info)
	end
end

-- Pre-split by rarity floor, for the two guarantees below. Both are built
-- from the same PullWeight-gated pool, so an ability that isn't obtainable
-- can never be handed out by a guarantee either.
local mythicPool: { Abilities.AbilityInfo } = {}
local floorPool: { Abilities.AbilityInfo } = {}
for _, info in pool do
	if RarityOrder.Of(info.Rarity) >= RarityOrder.Rank.Mythic then
		table.insert(mythicPool, info)
	end
	if RarityOrder.Of(info.Rarity) >= RarityOrder.TenPullFloor then
		table.insert(floorPool, info)
	end
end

local function weightFor(info: Abilities.AbilityInfo, lucky: boolean): number
	if lucky and info.LuckyPullWeight then
		return info.LuckyPullWeight
	end
	return info.PullWeight or 0
end

local function rollOne(lucky: boolean): Abilities.AbilityInfo
	local total = 0
	for _, info in pool do
		total += weightFor(info, lucky)
	end

	local roll = math.random() * total
	local cumulative = 0
	for _, info in pool do
		cumulative += weightFor(info, lucky)
		if roll <= cumulative then
			return info
		end
	end
	return pool[#pool] -- float rounding fallback; unreachable in practice
end

local function grantPull(profile, info: Abilities.AbilityInfo): (boolean, number)
	if table.find(profile.OwnedAbilities, info.Id) then
		profile.Points += DUPLICATE_REFUND_POINTS
		return false, DUPLICATE_REFUND_POINTS
	end
	table.insert(profile.OwnedAbilities, info.Id)
	return true, 0
end

local gachaResultRemote: RemoteEvent

-- Shared by both payment paths (points via PullGacha, Robux via
-- GrantRobuxPull) so the client's reveal animation only ever has to listen
-- to one event regardless of how the pull was paid for.
-- One roll, with the Mythic pity counter applied on top.
--
-- The counter is advanced on EVERY pull including the guaranteed one, so a
-- ten-pull that trips the pity at its third slot doesn't also trip it again
-- at its fourth -- the reset has already happened by then.
local function rollWithPity(profile, lucky: boolean): Abilities.AbilityInfo
	local info = rollOne(lucky)

	if RarityOrder.Of(info.Rarity) >= RarityOrder.Rank.Mythic then
		profile.PullsSinceMythic = 0
		return info
	end

	profile.PullsSinceMythic = (profile.PullsSinceMythic or 0) + 1
	if profile.PullsSinceMythic >= MYTHIC_PITY_PULLS and #mythicPool > 0 then
		profile.PullsSinceMythic = 0
		return mythicPool[math.random(#mythicPool)]
	end

	return info
end

-- The ten-pull's Epic-or-better guarantee.
--
-- This is the single change that stops a ten-pull being ten near-worthless
-- results: the pool is top-heavy with Commons (58.9% Sky Hop alone), so
-- without a floor a ten-pull comes back as ten duplicates far more often than
-- not, each refunding 50 points against a 1350-point-per-pull spend. The
-- floor is applied to the LAST slot because the reveal is sorted best-last
-- (see GachaController.startSequentialReveal) -- upgrading a slot the player
-- has already watched resolve would be invisible.
--
-- Deliberately applied to the rolled list BEFORE anything is granted, so the
-- upgraded slot goes through the same ownership and refund path as a natural
-- roll rather than needing a second, parallel grant.
local function applyTenPullFloor(rolls: { Abilities.AbilityInfo })
	if #floorPool == 0 then
		return
	end
	for _, info in rolls do
		if RarityOrder.Of(info.Rarity) >= RarityOrder.TenPullFloor then
			return
		end
	end
	rolls[#rolls] = floorPool[math.random(#floorPool)]
end

local function doPulls(player: Player, profile, count: number)
	local lucky = MonetizationService.HasLucky(player)

	local rolls: { Abilities.AbilityInfo } = {}
	for _ = 1, count do
		table.insert(rolls, rollWithPity(profile, lucky))
	end
	if count == 10 then
		applyTenPullFloor(rolls)
	end

	local results = {}
	for _, info in rolls do
		local isNew, refundPoints = grantPull(profile, info)
		table.insert(results, {
			Id = info.Id,
			Rarity = info.Rarity,
			IsNew = isNew,
			RefundPoints = refundPoints,
		})
	end
	-- The pity count rides along with the results rather than the client
	-- re-fetching its profile once the reveal ends. Two reasons: the bar should
	-- animate off the same event that plays the reveal, and a round-trip after
	-- a ten-pull would leave it reading a stale number for as long as the
	-- request took -- on the one screen where players are watching that number.
	gachaResultRemote:FireClient(player, results, profile.PullsSinceMythic)
end

local function handlePull(player: Player, count: number): (boolean, string)
	if count ~= 1 and count ~= 10 then
		return false, "Invalid pull count"
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return false, "Profile not loaded"
	end

	local cost = if count == 10 then TEN_PULL_POINTS_COST else SINGLE_PULL_POINTS_COST
	if profile.Points < cost then
		return false, "Not enough points"
	end

	profile.Points -= cost
	TelemetryService.Economy(
		player,
		false,
		"Points",
		cost,
		profile.Points,
		Enum.AnalyticsEconomyTransactionType.Shop,
		("GachaPull_x%d"):format(count)
	)
	doPulls(player, profile, count)
	return true, "Pulled"
end

-- Called from PurchaseService.processReceipt (that's the one place
-- MarketplaceService.ProcessReceipt is allowed to live -- see the comment
-- there) once a gacha Robux product's payment actually clears. Idempotent
-- against Roblox replaying the same receipt: see ProcessedPurchaseIds's
-- comment in PlayerDataService for why this has to be durable, not an
-- in-memory guard, unlike trail/emote grants.
function GachaService.GrantRobuxPull(player: Player, count: number, purchaseId: string): boolean
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return false
	end

	if profile.ProcessedPurchaseIds[purchaseId] then
		return true
	end
	profile.ProcessedPurchaseIds[purchaseId] = true

	doPulls(player, profile, count)
	return true
end

-- Called from SettingsController's toggle. Force-false if the player
-- doesn't actually own the gamepass -- enforced HERE, at the one place this
-- preference is ever written, so GachaController can just trust whatever
-- profile.SkipGachaAnimationEnabled says without re-checking ownership
-- itself every time it plays (or skips) a reveal.
local function handleSetSkipAnimation(player: Player, enabled: boolean): boolean
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return false
	end
	local actualEnabled = enabled and MonetizationService.HasSkipGachaAnimation(player)
	profile.SkipGachaAnimationEnabled = actualEnabled
	return actualEnabled
end

function GachaService.Init()
	local pullRemote = Net.CreateRemoteFunction(RemoteNames.PullGacha)
	pullRemote.OnServerInvoke = function(player: Player, count: number)
		return handlePull(player, count)
	end

	local setSkipRemote = Net.CreateRemoteFunction(RemoteNames.SetSkipGachaAnimation)
	setSkipRemote.OnServerInvoke = function(player: Player, enabled: boolean)
		return handleSetSkipAnimation(player, enabled == true)
	end

	gachaResultRemote = Net.CreateRemoteEvent(RemoteNames.GachaPullResult)

	local promptRobuxRemote = Net.CreateRemoteEvent(RemoteNames.PromptGachaRobuxPurchase)
	promptRobuxRemote.OnServerEvent:Connect(function(player: Player, count: number)
		local productId = if count == 10
			then GachaService.TEN_PULL_ROBUX_PRODUCT_ID
			else GachaService.SINGLE_PULL_ROBUX_PRODUCT_ID
		MarketplaceService:PromptProductPurchase(player, productId)
	end)

	-- Receipt granting lives in PurchaseService -- this only ever prompts the
	-- purchase above (same division of responsibility ShopService uses for
	-- trails).
end

return GachaService
