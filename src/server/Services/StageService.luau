local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local LeaderboardService = require(script.Parent.LeaderboardService)

-- Tag start/finish parts with CollectionService tags "StartLine" / "FinishLine"
-- and set a "StageId" string attribute on each to identify which stage they belong to.
local StageService = {}

local raceStartTimes = {}

local function getStageId(part: Instance): string?
	return part:GetAttribute("StageId")
end

local function onStartTouched(part: Instance, hit: BasePart)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	local stageId = player and getStageId(part)
	if not player or not stageId then
		return
	end

	raceStartTimes[player.UserId] = raceStartTimes[player.UserId] or {}
	raceStartTimes[player.UserId][stageId] = os.clock()
end

local function onFinishTouched(part: Instance, hit: BasePart)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	local stageId = player and getStageId(part)
	if not player or not stageId then
		return
	end

	local startTime = raceStartTimes[player.UserId] and raceStartTimes[player.UserId][stageId]
	if not startTime then
		return
	end

	raceStartTimes[player.UserId][stageId] = nil
	LeaderboardService.SubmitTime(player, stageId, os.clock() - startTime)
end

local function bindStart(part: Instance)
	if part:IsA("BasePart") then
		part.Touched:Connect(function(hit)
			onStartTouched(part, hit)
		end)
	end
end

local function bindFinish(part: Instance)
	if part:IsA("BasePart") then
		part.Touched:Connect(function(hit)
			onFinishTouched(part, hit)
		end)
	end
end

function StageService.Init()
	for _, part in CollectionService:GetTagged("StartLine") do
		bindStart(part)
	end
	for _, part in CollectionService:GetTagged("FinishLine") do
		bindFinish(part)
	end

	CollectionService:GetInstanceAddedSignal("StartLine"):Connect(bindStart)
	CollectionService:GetInstanceAddedSignal("FinishLine"):Connect(bindFinish)
end

return StageService
