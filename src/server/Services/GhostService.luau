local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Stores each player's fastest recorded run per stage (flat {x,y,z,x,y,z,...}
-- position array, sampled on a fixed clock -- see Constants.Ghost) so
-- Practice mode can play it back as a translucent ghost to race against.
-- Purely cosmetic: this never touches Elo, points, or the real leaderboard
-- (LeaderboardService, submitted separately from the actual finish), so it
-- doesn't need the same anti-cheat rigor as anything competitive -- just
-- enough validation that a malformed or hostile payload can't corrupt
-- storage or crash playback for the one player it would even affect.
local GhostService = {}

local MAX_SAMPLES = 3000 -- ~7.5 minutes at the default sample interval; generous but bounded
local MAX_COORDINATE = 100000 -- sanity bound, comfortably past any real stage's extent

local function getStore(stageId: string): DataStore?
	local success, store = pcall(function()
		return DataStoreService:GetDataStore("GhostData_" .. stageId)
	end)
	return if success then store else nil
end

local function isValidPositions(positions: { number }): boolean
	if typeof(positions) ~= "table" then
		return false
	end
	local count = #positions
	if count == 0 or count % 3 ~= 0 or count > MAX_SAMPLES * 3 then
		return false
	end
	for _, v in positions do
		if typeof(v) ~= "number" or v ~= v or math.abs(v) > MAX_COORDINATE then
			return false
		end
	end
	return true
end

function GhostService.GetGhostRun(player: Player, stageId: string)
	local store = getStore(stageId)
	if not store then
		return nil
	end

	local success, data = pcall(function()
		return store:GetAsync("Player_" .. player.UserId)
	end)
	if success and data then
		return data
	end
	return nil
end

-- Idempotent/safe to call with a worse time than what's stored -- only
-- overwrites if this run actually improves on the saved one, same rule as
-- LeaderboardService.SubmitTime.
local function submitGhostRun(player: Player, stageId: string, positions: { number }, timeMs: number)
	if typeof(stageId) ~= "string" or typeof(timeMs) ~= "number" or timeMs <= 0 or timeMs ~= timeMs then
		return
	end
	if not isValidPositions(positions) then
		return
	end

	local store = getStore(stageId)
	if not store then
		return
	end

	local key = "Player_" .. player.UserId
	local record = {
		Positions = positions,
		TimeMs = timeMs,
		SampleInterval = Constants.Ghost.SampleIntervalSeconds,
	}

	pcall(function()
		store:UpdateAsync(key, function(old)
			if old == nil or timeMs < old.TimeMs then
				return record
			end
			return old
		end)
	end)
end

function GhostService.Init()
	local getGhostRemote = Net.CreateRemoteFunction(RemoteNames.GetGhostRun)
	getGhostRemote.OnServerInvoke = function(player: Player, stageId: string)
		if typeof(stageId) ~= "string" then
			return nil
		end
		return GhostService.GetGhostRun(player, stageId)
	end

	local submitRemote = Net.CreateRemoteEvent(RemoteNames.SubmitGhostRun)
	submitRemote.OnServerEvent:Connect(function(player: Player, stageId: string, positions: { number }, timeMs: number)
		submitGhostRun(player, stageId, positions, timeMs)
	end)
end

return GhostService
