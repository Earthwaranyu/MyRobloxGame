local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Constants = require(Shared.Constants)

local LeaderboardService = {}

-- Friends' times are looked up individually (OrderedDataStore's sorted pages
-- only sort the *whole* store, not an arbitrary subset of keys), so this is
-- capped to keep both latency and DataStore request budget reasonable --
-- more than enough for "see how you stack up against people you actually
-- know", which is the point, versus wanting a complete census of every friend.
local MAX_FRIENDS_CHECKED = 40
local FRIENDS_FETCH_COOLDOWN = 5
local lastFriendsFetch: { [number]: number } = {}

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

	Players.PlayerRemoving:Connect(function(player: Player)
		lastFriendsFetch[player.UserId] = nil
	end)
end

return LeaderboardService
