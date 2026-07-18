local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Placeholder until a real Game Pass is created on the Creator Dashboard
-- (Monetization > Passes) and its id pasted in here -- UserOwnsGamePassAsync
-- is skipped entirely while this is 0, so nothing errors in the meantime.
local VIP_GAMEPASS_ID = 0

local MonetizationService = {}
MonetizationService.PointsMultiplier = 2

local vipCache: { [number]: boolean } = {}

local function refreshVIP(player: Player)
	if VIP_GAMEPASS_ID == 0 then
		vipCache[player.UserId] = false
		return
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, VIP_GAMEPASS_ID)
	end)
	vipCache[player.UserId] = ok and owns or false
end

function MonetizationService.HasVIP(player: Player): boolean
	return vipCache[player.UserId] or false
end

function MonetizationService.Init()
	Players.PlayerAdded:Connect(refreshVIP)
	Players.PlayerRemoving:Connect(function(player)
		vipCache[player.UserId] = nil
	end)
	for _, player in Players:GetPlayers() do
		refreshVIP(player)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if wasPurchased and gamePassId == VIP_GAMEPASS_ID then
			vipCache[player.UserId] = true
		end
	end)

	local promptRemote = Net.CreateRemoteEvent(RemoteNames.PromptVIPPurchase)
	promptRemote.OnServerEvent:Connect(function(player: Player)
		if VIP_GAMEPASS_ID ~= 0 then
			MarketplaceService:PromptGamePassPurchase(player, VIP_GAMEPASS_ID)
		end
	end)
end

return MonetizationService
