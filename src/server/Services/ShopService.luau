local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local PointBundles = require(Shared.PointBundles)
local RemoteNames = require(Shared.RemoteNames)
local Trails = require(Shared.Trails)

local PlayerDataService = require(script.Parent.PlayerDataService)

local ShopService = {}

-- Mirrors the equipped trail onto the character as a replicated attribute so
-- every client (not just the owner) can build the matching Trail effect --
-- see client/Controllers/TrailVisualsController.luau.
local function applyEquippedTrailAttribute(player: Player)
	local character = player.Character
	if not character then
		return
	end

	local profile = PlayerDataService.GetProfile(player)
	local attempts = 0
	while not profile and attempts < 100 do
		task.wait()
		profile = PlayerDataService.GetProfile(player)
		attempts += 1
	end
	if not profile then
		return
	end

	character:SetAttribute("EquippedTrail", profile.EquippedTrail)
end

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
	applyEquippedTrailAttribute(player)
	return true, "Equipped"
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

	local promptPointsRemote = Net.CreateRemoteEvent(RemoteNames.PromptPointsPurchase)
	promptPointsRemote.OnServerEvent:Connect(function(player: Player, productId: number)
		if typeof(productId) ~= "number" then
			return
		end
		-- Only ever prompts a product id that's actually a known bundle, so
		-- this remote can't be used to prompt an arbitrary Developer Product.
		for _, bundle in PointBundles do
			if bundle.RobuxProductId == productId then
				MarketplaceService:PromptProductPurchase(player, productId)
				break
			end
		end
	end)

	-- Receipt granting for every Developer Product in the game lives in
	-- PurchaseService (MarketplaceService.ProcessReceipt only takes one
	-- assignment game-wide) -- this only ever prompts the purchases above.

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			applyEquippedTrailAttribute(player)
		end)
	end)

	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function()
			applyEquippedTrailAttribute(player)
		end)
		if player.Character then
			applyEquippedTrailAttribute(player)
		end
	end
end

return ShopService
