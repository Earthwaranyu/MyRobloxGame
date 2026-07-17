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

function ShopService.Init()
	local purchaseRemote = Net.CreateRemoteFunction(RemoteNames.PurchaseTrail)
	purchaseRemote.OnServerInvoke = function(player: Player, trailId: string)
		return handlePurchase(player, trailId)
	end

	local equipRemote = Net.CreateRemoteFunction(RemoteNames.EquipTrail)
	equipRemote.OnServerInvoke = function(player: Player, trailId: string)
		return handleEquip(player, trailId)
	end
end

return ShopService
