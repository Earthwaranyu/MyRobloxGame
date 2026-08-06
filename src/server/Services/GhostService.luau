local DataStoreService = game:GetService("DataStoreService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

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

-- stageId is pasted straight into a DataStore NAME below, so it has to be one of
-- ours and not merely a string. The payload validation here is already careful
-- (see isValidPositions), but a well-formed run submitted under an invented
-- stage id would still have the server create and write an unlimited number of
-- stores. Same check LeaderboardService does before its own getStore, and for
-- the same reason.
local function isKnownStage(stageId: unknown): boolean
	if typeof(stageId) ~= "string" then
		return false
	end
	for _, stage in Stages do
		if stage.Id == stageId then
			return true
		end
	end
	return false
end

-- Bumped from "GhostData_" when runs became stage-RELATIVE (see stageOrigin).
-- Every record written before that is a list of absolute world coordinates from
-- wherever the stages used to sit, and re-reading one now would replay a ghost
-- hundreds of studs outside its own room. A new store name retires them all
-- rather than trying to detect and migrate them.
local STORE_PREFIX = "GhostRelative_"

local function getStore(stageId: string): DataStore?
	local success, store = pcall(function()
		return DataStoreService:GetDataStore(STORE_PREFIX .. stageId)
	end)
	return if success then store else nil
end

-- The point a stage's ghost samples are stored relative to.
--
-- Runs used to be saved as raw world positions, which quietly assumed a stage
-- would never move. StagePlacementService now lays all eight out on a grid at
-- server start, so that assumption broke and a saved run played back at the
-- stage's OLD coordinates -- visible from inside the room as a ghost running
-- through the wall and away across the map.
--
-- The void slab is the anchor: every stage has exactly one, it spans the whole
-- course, and StagePlacementService positions the stage BY it -- so it is the
-- one part guaranteed to move in lockstep with everything a ghost was recorded
-- against. Storing offsets from it makes a run independent of where the stage
-- happens to be laid out today.
local function stageOrigin(stageId: string): Vector3?
	local stages = Workspace:FindFirstChild("Stages")
	local folder = stages and stages:FindFirstChild(stageId)
	if not folder then
		return nil
	end
	for _, part in folder:GetDescendants() do
		if part:IsA("BasePart") and part.Name == "VoidZone" then
			return part.Position
		end
	end
	return nil
end

-- Shifts a flat {x,y,z,x,y,z,...} run by a constant. Used in both directions:
-- world -> stage-local on the way into storage, stage-local -> world on the way
-- back out, so the CLIENT only ever deals in world space and needs no changes.
local function shiftPositions(positions: { number }, offset: Vector3): { number }
	local shifted = table.create(#positions)
	for i = 1, #positions - 2, 3 do
		shifted[i] = positions[i] + offset.X
		shifted[i + 1] = positions[i + 1] + offset.Y
		shifted[i + 2] = positions[i + 2] + offset.Z
	end
	return shifted
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
	if success and data and typeof(data.Positions) == "table" then
		local origin = stageOrigin(stageId)
		if not origin then
			return nil
		end
		-- Back into world space for the client, which plays ghosts back exactly
		-- where it records them.
		return {
			Positions = shiftPositions(data.Positions, origin),
			TimeMs = data.TimeMs,
			SampleInterval = data.SampleInterval,
		}
	end
	return nil
end

-- Idempotent/safe to call with a worse time than what's stored -- only
-- overwrites if this run actually improves on the saved one, same rule as
-- LeaderboardService.SubmitTime.
local function submitGhostRun(player: Player, stageId: string, positions: { number }, timeMs: number)
	if not isKnownStage(stageId) or typeof(timeMs) ~= "number" or timeMs <= 0 or timeMs ~= timeMs then
		return
	end
	if not isValidPositions(positions) then
		return
	end

	local store = getStore(stageId)
	if not store then
		return
	end

	-- Simulated Studio clients have negative UserIds and shouldn't leave ghost
	-- runs in the live store (see LeaderboardService.isRealAccount).
	if player.UserId <= 0 then
		return
	end

	local origin = stageOrigin(stageId)
	if not origin then
		return
	end

	local key = "Player_" .. player.UserId
	local record = {
		-- Stored relative to the stage, so the run survives the stage being
		-- laid out somewhere else on a later server.
		Positions = shiftPositions(positions, -origin),
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
		if not isKnownStage(stageId) then
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
