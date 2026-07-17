local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Trails = require(Shared.Trails)

local PlayerDataService = require(script.Parent.PlayerDataService)

local ShopService = {}

local function handlePurchase(player: Player, trailId: string): (boolean, string)
	local trail = Trails[trailId]
	local profile = PlayerDataService.GetProfile(player)

	if not trail or not profile then
		return false, "Invalid request"
	end

	if table.find(profile.OwnedTrails, trailId) then
		return false, "Already owned"
	end

	if profile.Points < trail.PointsCost then
		return false, "Not enough points"
	end

	profile.Points -= trail.PointsCost
	table.insert(profile.OwnedTrails, trailId)

	return true, "Purchased"
end

-- trailId == "" unequips.
local function handleEquip(player: Player, trailId: string): (boolean, string)
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return false, "Profile not loaded"
	end

	if trailId ~= "" and not table.find(profile.OwnedTrails, trailId) then
		return false, "Not owned"
	end

	profile.EquippedTrail = trailId
	return true, "Equipped"
end

local function findTrailByProductId(productId: number): string?
	for trailId, trail in Trails do
		if trail.RobuxProductId == productId then
			return trailId
		end
	end
	return nil
end

-- Roblox requires this to be idempotent: a receipt can be replayed if the
-- prior call didn't return PurchaseGranted in time, so re-granting an already
-- owned trail must be a safe no-op rather than an error.
local function processReceipt(receiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local trailId = findTrailByProductId(receiptInfo.ProductId)
	local profile = PlayerDataService.GetProfile(player)
	if not trailId or not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not table.find(profile.OwnedTrails, trailId) then
		table.insert(profile.OwnedTrails, trailId)
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function ShopService.Init()
	local purchaseRemote = Net.CreateRemoteFunction(RemoteNames.PurchaseTrail)
	purchaseRemote.OnServerInvoke = function(player: Player, trailId: string)
		return handlePurchase(player, trailId)
	end

	local equipRemote = Net.CreateRemoteFunction(RemoteNames.EquipTrail)
	equipRemote.OnServerInvoke = function(player: Player, trailId: string)
		return handleEquip(player, trailId)
	end

	local promptRobuxRemote = Net.CreateRemoteEvent(RemoteNames.PromptRobuxPurchase)
	promptRobuxRemote.OnServerEvent:Connect(function(player: Player, trailId: string)
		local trail = Trails[trailId]
		if trail and trail.RobuxProductId then
			MarketplaceService:PromptProductPurchase(player, trail.RobuxProductId)
		end
	end)

	MarketplaceService.ProcessReceipt = processReceipt
end

return ShopService
