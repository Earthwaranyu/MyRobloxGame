local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- DataStoreService:GetDataStore() throws if API access is disabled (e.g. an
-- unpublished place in Studio), so this is deferred and guarded rather than
-- fetched at module load time.
local function getStore(): DataStore?
	local success, store = pcall(function()
		return DataStoreService:GetDataStore("PlayerData_v1")
	end)
	return if success then store else nil
end

local DEFAULT_PROFILE = {
	Elo = Constants.Elo.StartingRating,
	Points = 0,
	OwnedTrails = { "Basic" },
	EquippedTrail = "Basic",
}

local PlayerDataService = {}

local profiles = {}

local function loadProfile(player: Player)
	local store = getStore()
	local data = nil

	if store then
		local success, result = pcall(function()
			return store:GetAsync("Player_" .. player.UserId)
		end)
		if success then
			data = result
		else
			warn(("Failed to load data for %s: %s"):format(player.Name, tostring(result)))
		end
	end

	local profile = data or table.clone(DEFAULT_PROFILE)
	for key, value in DEFAULT_PROFILE do
		if profile[key] == nil then
			profile[key] = value
		end
	end

	profiles[player.UserId] = profile
end

local function saveProfile(player: Player)
	local profile = profiles[player.UserId]
	local store = getStore()
	if not profile or not store then
		return
	end

	local success, err = pcall(function()
		store:SetAsync("Player_" .. player.UserId, profile)
	end)

	if not success then
		warn(("Failed to save data for %s: %s"):format(player.Name, tostring(err)))
	end
end

function PlayerDataService.GetProfile(player: Player)
	return profiles[player.UserId]
end

function PlayerDataService.Init()
	Players.PlayerAdded:Connect(loadProfile)
	Players.PlayerRemoving:Connect(function(player)
		saveProfile(player)
		profiles[player.UserId] = nil
	end)

	for _, player in Players:GetPlayers() do
		loadProfile(player)
	end

	local getProfileRemote = Net.CreateRemoteFunction(RemoteNames.GetProfile)
	getProfileRemote.OnServerInvoke = function(player: Player)
		-- loadProfile may still be in flight (e.g. an async DataStore read)
		-- when the client asks, so wait briefly instead of returning nil.
		local attempts = 0
		while not profiles[player.UserId] and attempts < 100 do
			task.wait()
			attempts += 1
		end
		return profiles[player.UserId]
	end
end

return PlayerDataService
