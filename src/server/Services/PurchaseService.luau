local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Emotes = require(Shared.Emotes)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Trails = require(Shared.Trails)

local PlayerDataService = require(script.Parent.PlayerDataService)

-- MarketplaceService.ProcessReceipt is a single property -- only the last
-- assignment wins, so every Developer Product across the whole game (trails,
-- emotes, whatever comes next) has to be granted from ONE place. This is
-- that place; ShopService/EmoteService only ever call PromptProductPurchase
-- (fine to call from multiple spots) and never touch ProcessReceipt.
local PurchaseService = {}

-- Fired the instant a trail/emote is actually granted -- not the same moment
-- as the purchase dialog closing client-side (MarketplaceService.
-- PromptProductPurchaseFinished), which can fire slightly before ProcessReceipt
-- actually runs. ShopController/EmoteController refresh their "owned" state
-- off this instead of the prompt-finished event, so the UI can't show stale
-- "not owned yet" right after a purchase that already went through.
local purchaseGrantedRemote: RemoteEvent

local function findTrailId(productId: number): string?
	for trailId, trail in Trails do
		if trail.RobuxProductId == productId then
			return trailId
		end
	end
	return nil
end

local function findEmoteId(productId: number): string?
	for _, emote in Emotes do
		if emote.RobuxProductId == productId then
			return emote.Id
		end
	end
	return nil
end

-- Roblox requires this to be idempotent: a receipt can be replayed if the
-- prior call didn't return PurchaseGranted in time, so re-granting an
-- already-owned item must be a safe no-op rather than an error.
local function processReceipt(receiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local trailId = findTrailId(receiptInfo.ProductId)
	if trailId then
		if not table.find(profile.OwnedTrails, trailId) then
			table.insert(profile.OwnedTrails, trailId)
		end
		purchaseGrantedRemote:FireClient(player)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local emoteId = findEmoteId(receiptInfo.ProductId)
	if emoteId then
		profile.OwnedEmotes = profile.OwnedEmotes or {}
		if not table.find(profile.OwnedEmotes, emoteId) then
			table.insert(profile.OwnedEmotes, emoteId)
		end
		purchaseGrantedRemote:FireClient(player)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function PurchaseService.Init()
	purchaseGrantedRemote = Net.CreateRemoteEvent(RemoteNames.PurchaseGranted)
	MarketplaceService.ProcessReceipt = processReceipt
end

return PurchaseService
