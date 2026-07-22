local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Constants = require(Shared.Constants)
local Stages = require(Shared.Stages)

local LeaderboardService = {}

-- Friends' times are looked up individually (OrderedDataStore's sorted pages
-- only sort the *whole* store, not an arbitrary subset of keys), so this is
-- capped to keep both latency and DataStore request budget reasonable --
-- more than enough for "see how you stack up against people you actually
-- know", which is the point, versus wanting a complete census of every friend.
local MAX_FRIENDS_CHECKED = 40
local FRIENDS_FETCH_COOLDOWN = 5
local lastFriendsFetch: { [number]: number } = {}

-- Profile card's "Best Times" section costs one GetAsync per stage -- unlike
-- every other field on GetPlayerProfileSummary, which is free in-memory
-- profile data (see PlayerDataService). Gated behind its own per-VIEWER
-- cooldown, same defensive shape as FRIENDS_FETCH_COOLDOWN just keyed on
-- whichever caller is asking rather than whichever stage is being read, so
-- double-clicking through a crowd of players can't burn through the
-- DataStore request budget.
local BEST_TIMES_COOLDOWN = 2
local lastBestTimesFetch: { [number]: number } = {}

-- GetOrderedDataStore() throws if API access is disabled (e.g. an unpublished
-- place in Studio), so this is guarded rather than called directly.
local function getStore(stageId: string): OrderedDataStore?
	local success, store = pcall(function()
		return DataStoreService:GetOrderedDataStore("StageTimes_" .. stageId)
	end)
	return if success then store else nil
end

local function resolveName(userId: number): string
	local name = "Player" .. tostring(userId)
	local success, result = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if success then
		name = result
	end
	return name
end

-- Unlike the global top-100 (one sorted read), this is a handful of
-- individual GetAsync calls -- one per friend -- so it's gated behind its
-- own short cooldown (see GetLeaderboard's remote handler) to keep someone
-- spam-clicking the Friends tab from burning through the server's DataStore
-- request budget.
function LeaderboardService.GetFriendTimes(player: Player, stageId: string)
	local store = getStore(stageId)
	if not store then
		return {}
	end

	local userIds = { player.UserId }
	local success, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)
	if success then
		local ok, currentPage = pcall(function()
			return pages:GetCurrentPage()
		end)
		if ok then
			for _, friendInfo in currentPage do
				table.insert(userIds, friendInfo.Id)
				if #userIds >= MAX_FRIENDS_CHECKED then
					break
				end
			end
		end
	end

	local results = {}
	for _, userId in userIds do
		local ok, value = pcall(function()
			return store:GetAsync("Player_" .. userId)
		end)
		if ok and value then
			table.insert(results, { Name = resolveName(userId), TimeMs = value })
		end
	end

	table.sort(results, function(a, b)
		return a.TimeMs < b.TimeMs
	end)

	for i, entry in results do
		entry.Rank = i
	end

	return results
end

-- One player's best time on one stage, in ms -- nil if they've never finished
-- it. Used by the profile card (see PlayerDataService.GetPlayerProfileSummary)
-- to show best-time-per-stage for whoever was double-clicked, same single-key
-- GetAsync pattern GetFriendTimes already uses per friend, just for one userId.
function LeaderboardService.GetPlayerBestTime(userId: number, stageId: string): number?
	local store = getStore(stageId)
	if not store then
		return nil
	end

	local ok, value = pcall(function()
		return store:GetAsync("Player_" .. userId)
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return nil
end

-- Lower time is better; only writes when it improves the player's best.
function LeaderboardService.SubmitTime(player: Player, stageId: string, timeSeconds: number)
	local store = getStore(stageId)
	if not store then
		return
	end

	local key = "Player_" .. player.UserId
	local timeInMs = math.floor(timeSeconds * 1000)

	local success, err = pcall(function()
		store:UpdateAsync(key, function(oldValue)
			if oldValue == nil or timeInMs < oldValue then
				return timeInMs
			end
			return oldValue
		end)
	end)

	if not success then
		warn(("Failed to submit time for %s on %s: %s"):format(player.Name, stageId, tostring(err)))
	end
end

function LeaderboardService.GetTopTimes(stageId: string, count: number?)
	local store = getStore(stageId)
	if not store then
		return {}
	end

	local success, pages = pcall(function()
		return store:GetSortedAsync(true, count or 100)
	end)

	if not success then
		warn(("Failed to fetch leaderboard for %s: %s"):format(stageId, tostring(pages)))
		return {}
	end

	return pages:GetCurrentPage()
end

-- Global Elo store -- ONE store (not per-stage like getStore(stageId)
-- above), since rank is a whole-game concept, not tied to any single stage.
-- Backs the physical world leaderboard board (see LeaderboardBoardService).
local function getEloStore(): OrderedDataStore?
	local success, store = pcall(function()
		return DataStoreService:GetOrderedDataStore("PlayerElo")
	end)
	return if success then store else nil
end

-- Elo can go DOWN (unlike best-time, which only ever improves), so this
-- always overwrites with the current value rather than SubmitTime's
-- UpdateAsync-only-if-better pattern. A plain SetAsync write, so -- unlike
-- GetSortedAsync reads -- this is cheap enough to call on every match end
-- with no cooldown needed (same as SubmitTime already does per-race).
function LeaderboardService.SubmitElo(player: Player, elo: number)
	local store = getEloStore()
	if not store then
		return
	end

	local success, err = pcall(function()
		store:SetAsync("Player_" .. player.UserId, elo)
	end)
	if not success then
		warn(("Failed to submit Elo for %s: %s"):format(player.Name, tostring(err)))
	end
end

-- Names pre-resolved (unlike GetTopTimes, whose raw key/value pairs get
-- resolved by GetLeaderboard's remote handler below) since the only current
-- caller is LeaderboardBoardService, which has no remote/client round trip
-- of its own to do that resolving in.
function LeaderboardService.GetTopElo(count: number?)
	local store = getEloStore()
	if not store then
		return {}
	end

	local success, pages = pcall(function()
		return store:GetSortedAsync(false, count or 10)
	end)

	if not success then
		warn(("Failed to fetch global Elo leaderboard: %s"):format(tostring(pages)))
		return {}
	end

	local entries = {}
	for i, entry in pages:GetCurrentPage() do
		local userId = tonumber((entry.key :: string):match("_(%d+)$"))
		local name = if userId then resolveName(userId) else entry.key
		entries[i] = { Rank = i, Name = name, Elo = entry.value }
	end
	return entries
end

function LeaderboardService.Init()
	local remote = Net.CreateRemoteFunction(RemoteNames.GetLeaderboard)
	remote.OnServerInvoke = function(player: Player, stageId: string, friendsOnly: boolean?)
		if friendsOnly then
			local userId = player.UserId
			local now = os.clock()
			if lastFriendsFetch[userId] and now - lastFriendsFetch[userId] < FRIENDS_FETCH_COOLDOWN then
				return {}
			end
			lastFriendsFetch[userId] = now
			return LeaderboardService.GetFriendTimes(player, stageId)
		end

		local rawEntries = LeaderboardService.GetTopTimes(stageId, Constants.Leaderboard.TopCount)
		local entries = {}

		for i, entry in rawEntries do
			local userId = tonumber((entry.key :: string):match("_(%d+)$"))
			local name = if userId then resolveName(userId) else entry.key
			entries[i] = { Rank = i, Name = name, TimeMs = entry.value }
		end

		return entries
	end

	-- Separate from GetPlayerProfileSummary on purpose (see PlayerDataService)
	-- so opening the profile card never blocks on this -- the client opens the
	-- card off the fast in-memory summary fields and calls this afterward,
	-- filling in Best Times a beat later instead of stalling the whole panel
	-- behind a DataStore round trip. Fetches every stage in parallel (each
	-- GetAsync is its own network request) rather than one after another, so
	-- this takes as long as the SLOWEST single stage lookup, not the sum of
	-- all of them.
	local getBestTimesRemote = Net.CreateRemoteFunction(RemoteNames.GetPlayerBestTimes)
	getBestTimesRemote.OnServerInvoke = function(viewer: Player, targetUserId: number)
		if typeof(targetUserId) ~= "number" then
			return {}
		end

		local viewerId = viewer.UserId
		local now = os.clock()
		if lastBestTimesFetch[viewerId] and now - lastBestTimesFetch[viewerId] < BEST_TIMES_COOLDOWN then
			return {}
		end
		lastBestTimesFetch[viewerId] = now

		local bestTimes: { [string]: number? } = {}
		local remaining = #Stages
		for _, stage in Stages do
			task.spawn(function()
				bestTimes[stage.Id] = LeaderboardService.GetPlayerBestTime(targetUserId, stage.Id)
				remaining -= 1
			end)
		end
		while remaining > 0 do
			task.wait()
		end

		return bestTimes
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		lastFriendsFetch[player.UserId] = nil
		lastBestTimesFetch[player.UserId] = nil
	end)
end

return LeaderboardService
