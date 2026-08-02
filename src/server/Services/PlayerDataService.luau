local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local ProfileSchema = require(Shared.ProfileSchema)
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

local PlayerDataService = {}

local profiles = {}
-- os.time() (real wall-clock, stable across server restarts), not os.clock()
-- (resets every server run) -- see GetLiveTotalPlaySeconds.
local sessionStartTime: { [number]: number } = {}

-- Retries around every DataStore call. Transient failures (throttling, a brief
-- Roblox-side outage) are normal rather than exceptional, and the cost of
-- treating one as final is severe on both sides -- see saveBlocked below for
-- the read half, and saveProfile for the write half.
local DATASTORE_ATTEMPTS = 4
local DATASTORE_RETRY_DELAY = 1.5

local function withRetry<T>(label: string, fn: () -> T): (boolean, T?)
	local lastErr
	for attempt = 1, DATASTORE_ATTEMPTS do
		local success, result = pcall(fn)
		if success then
			return true, result
		end
		lastErr = result
		if attempt < DATASTORE_ATTEMPTS then
			task.wait(DATASTORE_RETRY_DELAY * attempt)
		end
	end
	warn(("%s failed after %d attempts: %s"):format(label, DATASTORE_ATTEMPTS, tostring(lastErr)))
	return false, nil
end

-- Players whose profile could NOT be read. Their in-memory profile is a default
-- one, which is emphatically not the same thing as their real data.
--
-- Saving one of these would overwrite a real, populated save with a blank
-- profile -- wiping rating, points, purchases and cosmetics because of a single
-- transient read failure. It's the classic Roblox data-loss bug and it only
-- ever shows up in production, since Studio has no DataStore access to fail in
-- the first place: every load here "fails" identically and harmlessly.
local saveBlocked: { [number]: boolean } = {}

local function loadProfile(player: Player)
	local store = getStore()
	local data = nil
	-- Cleared up front so a stale entry can never outlive the session it
	-- belonged to and block a healthy load's save.
	saveBlocked[player.UserId] = nil

	if store then
		local ok, result = withRetry("Load for " .. player.Name, function()
			return store:GetAsync("Player_" .. player.UserId)
		end)
		if ok then
			data = result
		else
			-- A nil result from a SUCCESSFUL read means a genuinely new player
			-- and is perfectly safe to save over. A failed read means we simply
			-- don't know, so this session becomes read-only.
			saveBlocked[player.UserId] = true
		end
	end

	-- Migration and default-fill both live in ProfileSchema, which is pure and
	-- therefore actually tested (see tests/spec.luau). It is also what stops
	-- every player in a server sharing one OwnedTrails table -- read the
	-- deepCopy note there before touching it.
	profiles[player.UserId] = ProfileSchema.New(data)
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

-- Returns whether the profile is now safely on disk, so callers that must not
-- acknowledge something until it's durable (see PurchaseService) can tell.
local function saveProfile(player: Player): boolean
	local profile = profiles[player.UserId]
	local store = getStore()
	if not profile then
		return false
	end
	-- Studio's simulated test clients have negative UserIds. Persisting them
	-- fills the live store with junk profiles keyed to accounts that don't
	-- exist. Reported as success: there is nothing to lose, and a caller
	-- waiting on durability (PurchaseService) must not stall on a fake player.
	if player.UserId <= 0 then
		return true
	end
	-- No store at all means DataStores are unavailable for the whole place
	-- (an unpublished Studio session). Nothing can be persisted and nothing can
	-- be lost, so this isn't a failure worth blocking callers on.
	if not store then
		return true
	end

	-- Refuse rather than overwrite. This session's profile is a default one
	-- standing in for data we couldn't read, so writing it would destroy the
	-- real save. Losing one session's progress is bad; losing the account is
	-- not recoverable.
	if saveBlocked[player.UserId] then
		warn(
			("Skipping save for %s -- their profile never loaded, so saving would overwrite real data"):format(
				player.Name
			)
		)
		return false
	end

	flushSessionPlaytime(player)

	local ok = withRetry("Save for " .. player.Name, function()
		store:SetAsync("Player_" .. player.UserId, profile)
	end)
	return ok
end

-- Persists NOW rather than waiting for the player to leave, and reports whether
-- it worked.
--
-- For anything bought with Robux: Roblox treats a receipt as consumed the moment
-- ProcessReceipt returns PurchaseGranted, so acknowledging a purchase that only
-- exists in memory means a server crash (or a failed save on the way out) takes
-- the item and keeps the money. See PurchaseService.
function PlayerDataService.SaveNow(player: Player): boolean
	return saveProfile(player)
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
		saveBlocked[player.UserId] = nil
	end)

	for _, player in Players:GetPlayers() do
		loadProfile(player)
	end

	-- PlayerRemoving alone only saves someone who leaves individually -- a
	-- full server shutdown (deploy, crash, Roblox-initiated restart) ends the
	-- server without ever firing that per-player event, so everyone still
	-- connected would lose their whole session with no save. Save everyone in
	-- parallel and block close until they've all finished (or errored out via
	-- saveProfile's own pcall) rather than saving one at a time.
	game:BindToClose(function()
		local players = Players:GetPlayers()
		local remaining = #players
		for _, player in players do
			task.spawn(function()
				saveProfile(player)
				remaining -= 1
			end)
		end
		while remaining > 0 do
			task.wait()
		end
	end)

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

		-- Best-times-per-stage deliberately NOT included here -- that needs a
		-- DataStore GetAsync per stage (see LeaderboardService's
		-- GetPlayerBestTimes remote), and blocking the profile card's open on
		-- that made double-clicking someone feel slow. Everything below is
		-- free in-memory profile data, so this call stays fast and the client
		-- opens the card off it immediately, then fetches best times
		-- separately afterward.
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
