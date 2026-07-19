local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RankTiers = require(Shared.RankTiers)
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
	WinStreak = 0,
	BestWinStreak = 0,
	LastLoginDate = "",
	DailyStreak = 0,
	AwardedBadgeKeys = {},
	OwnedEmotes = {},
	HasSeenTutorial = false,
	-- Ranked-race record only (bot/practice matches deliberately don't touch
	-- these -- see MatchService.PlayerReachedFinish -- since "win rate" here
	-- means the same thing the Elo ladder already means: real opponents only).
	Wins = 0,
	Losses = 0,
	-- Dash is free and owned by everyone by default; anything else here came
	-- from a gacha pull (see GachaService). EquippedAbility is always one of
	-- the ids in this list (enforced by AbilityService.handleEquip).
	OwnedAbilities = { "Dash" },
	EquippedAbility = "Dash",
	-- Guards non-idempotent Robux grants (gacha pulls, points bundles --
	-- see GachaService.GrantRobuxPull and PurchaseService's point-bundle
	-- branch) against MarketplaceService replaying the same receipt twice.
	-- Stored on the profile itself (durable via DataStore) rather than an
	-- in-memory set, since unlike trail/emote grants (which are already
	-- idempotent via a plain ownership check) these consume something
	-- real -- a random roll, or a points balance -- that would double up on
	-- replay otherwise. One shared set keyed by PurchaseId (a globally
	-- unique GUID) works fine across different grant types.
	ProcessedPurchaseIds = {},
	-- Whether gacha pulls skip straight to the result instead of playing the
	-- reveal animation. A per-player preference, not just a session toggle
	-- (see GachaService.SetSkipAnimation), so it doesn't reset every time
	-- someone rejoins -- but only ever true if they actually own the Skip
	-- Animation gamepass, enforced server-side at the point it's set, not
	-- read back out here.
	SkipGachaAnimationEnabled = false,
	-- Wall-clock seconds accumulated across past sessions; the current
	-- session's elapsed time is added on top at read time (see
	-- PlayerDataService.GetLiveTotalPlaySeconds) rather than kept live in this
	-- field, so a server crash only loses the current session, not history.
	TotalPlaySeconds = 0,
}

local PlayerDataService = {}

local profiles = {}
-- os.time() (real wall-clock, stable across server restarts), not os.clock()
-- (resets every server run) -- see GetLiveTotalPlaySeconds.
local sessionStartTime: { [number]: number } = {}

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
	sessionStartTime[player.UserId] = os.time()
end

-- Folds the current session's elapsed time into the persisted total. Called
-- right before every save so TotalPlaySeconds on disk is never stale by more
-- than one session, and so repeated calls (e.g. a future periodic autosave)
-- don't double-count -- each call resets the session start to "now".
local function flushSessionPlaytime(player: Player)
	local profile = profiles[player.UserId]
	local startedAt = sessionStartTime[player.UserId]
	if not profile or not startedAt then
		return
	end
	profile.TotalPlaySeconds += math.max(0, os.time() - startedAt)
	sessionStartTime[player.UserId] = os.time()
end

local function saveProfile(player: Player)
	local profile = profiles[player.UserId]
	local store = getStore()
	if not profile or not store then
		return
	end

	flushSessionPlaytime(player)

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

-- Stored TotalPlaySeconds plus whatever's elapsed in the current session --
-- for a profile card viewing someone mid-session, the stored value alone
-- would look frozen from whenever they last left the game.
function PlayerDataService.GetLiveTotalPlaySeconds(player: Player): number
	local profile = profiles[player.UserId]
	if not profile then
		return 0
	end
	local startedAt = sessionStartTime[player.UserId]
	local liveElapsed = if startedAt then math.max(0, os.time() - startedAt) else 0
	return profile.TotalPlaySeconds + liveElapsed
end

function PlayerDataService.Init()
	Players.PlayerAdded:Connect(loadProfile)
	Players.PlayerRemoving:Connect(function(player)
		saveProfile(player)
		profiles[player.UserId] = nil
		sessionStartTime[player.UserId] = nil
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

	-- Backs the double-click "profile card" (see ProfileCardController):
	-- rank/win-rate/playtime for whichever OTHER player was clicked, not the
	-- caller's own profile, so no wait-for-load loop is needed here -- if the
	-- target's profile hasn't loaded yet there's nothing meaningful to show.
	local getSummaryRemote = Net.CreateRemoteFunction(RemoteNames.GetPlayerProfileSummary)
	getSummaryRemote.OnServerInvoke = function(_player: Player, targetUserId: number)
		if typeof(targetUserId) ~= "number" then
			return nil
		end
		local target = Players:GetPlayerByUserId(targetUserId)
		local profile = target and profiles[targetUserId]
		if not target or not profile then
			return nil
		end

		local totalGames = profile.Wins + profile.Losses
		local winRate = if totalGames > 0 then profile.Wins / totalGames else 0

		return {
			Name = target.Name,
			Elo = profile.Elo,
			Rank = RankTiers.GetRankForElo(profile.Elo),
			Wins = profile.Wins,
			Losses = profile.Losses,
			WinRate = winRate,
			PlaytimeSeconds = PlayerDataService.GetLiveTotalPlaySeconds(target),
			EquippedAbility = profile.EquippedAbility,
		}
	end
end

return PlayerDataService
