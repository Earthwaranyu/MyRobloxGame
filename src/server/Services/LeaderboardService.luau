local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Constants = require(Shared.Constants)

local LeaderboardService = {}

-- GetOrderedDataStore() throws if API access is disabled (e.g. an unpublished
-- place in Studio), so this is guarded rather than called directly.
local function getStore(stageId: string): OrderedDataStore?
	local success, store = pcall(function()
		return DataStoreService:GetOrderedDataStore("StageTimes_" .. stageId)
	end)
	return if success then store else nil
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
	remote.OnServerInvoke = function(_player: Player, stageId: string)
		local rawEntries = LeaderboardService.GetTopTimes(stageId, Constants.Leaderboard.TopCount)
		local entries = {}

		for i, entry in rawEntries do
			local userId = tonumber((entry.key :: string):match("_(%d+)$"))
			local name = userId and ("Player" .. tostring(userId)) or entry.key

			if userId then
				local success, result = pcall(Players.GetNameFromUserIdAsync, Players, userId)
				if success then
					name = result
				end
			end

			entries[i] = { Rank = i, Name = name, TimeMs = entry.value }
		end

		return entries
	end
end

return LeaderboardService
