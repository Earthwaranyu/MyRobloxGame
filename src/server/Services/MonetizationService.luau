local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Every gamepass in the game funnels through one small owned-cache/refresh/
-- prompt setup below instead of three near-identical copies of the same
-- MarketplaceService dance -- see GAMEPASS_IDS for the actual passes.
local GAMEPASS_IDS: { [string]: number } = {
	VIP = 3610509225,
	-- "Lucky" -- better gacha odds (see Abilities.luau's LuckyPullWeight and
	-- GachaService).
	Lucky = 1918173228,
	-- Skips the gacha pull reveal animation straight to the result (see
	-- GachaController) -- a convenience purchase, not a power purchase.
	SkipGachaAnimation = 1917525263,
}

local MonetizationService = {}
MonetizationService.PointsMultiplier = 2

local ownedCache: { [string]: { [number]: boolean } } = {}
for name in GAMEPASS_IDS do
	ownedCache[name] = {}
end

local function refreshGamepass(player: Player, name: string)
	local id = GAMEPASS_IDS[name]
	if id == 0 then
		ownedCache[name][player.UserId] = false
		return
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
	end)
	ownedCache[name][player.UserId] = ok and owns or false
end

local function refreshAll(player: Player)
	for name in GAMEPASS_IDS do
		refreshGamepass(player, name)
	end
end

function MonetizationService.HasVIP(player: Player): boolean
	return ownedCache.VIP[player.UserId] or false
end

function MonetizationService.HasLucky(player: Player): boolean
	return ownedCache.Lucky[player.UserId] or false
end

function MonetizationService.HasSkipGachaAnimation(player: Player): boolean
	return ownedCache.SkipGachaAnimation[player.UserId] or false
end

local function wirePromptRemote(remoteName: string, gamepassName: string)
	local remote = Net.CreateRemoteEvent(remoteName)
	remote.OnServerEvent:Connect(function(player: Player)
		local id = GAMEPASS_IDS[gamepassName]
		if id ~= 0 then
			MarketplaceService:PromptGamePassPurchase(player, id)
		end
	end)
end

function MonetizationService.Init()
	Players.PlayerAdded:Connect(refreshAll)
	Players.PlayerRemoving:Connect(function(player)
		for name in GAMEPASS_IDS do
			ownedCache[name][player.UserId] = nil
		end
	end)
	for _, player in Players:GetPlayers() do
		refreshAll(player)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then
			return
		end
		for name, id in GAMEPASS_IDS do
			if id == gamePassId then
				ownedCache[name][player.UserId] = true
			end
		end
	end)

	wirePromptRemote(RemoteNames.PromptVIPPurchase, "VIP")
	wirePromptRemote(RemoteNames.PromptLuckyPurchase, "Lucky")
	wirePromptRemote(RemoteNames.PromptSkipGachaAnimationPurchase, "SkipGachaAnimation")

	-- Gamepass ownership itself is never persisted on the profile (it's a
	-- live MarketplaceService check cached above, not a DataStore field), so
	-- UI that needs to know it -- e.g. GachaController deciding whether to
	-- show the Skip Animation toggle -- asks here instead of via GetProfile.
	local statusRemote = Net.CreateRemoteFunction(RemoteNames.GetMonetizationStatus)
	statusRemote.OnServerInvoke = function(player: Player)
		return {
			HasVIP = MonetizationService.HasVIP(player),
			HasLucky = MonetizationService.HasLucky(player),
			HasSkipGachaAnimation = MonetizationService.HasSkipGachaAnimation(player),
		}
	end
end

return MonetizationService
