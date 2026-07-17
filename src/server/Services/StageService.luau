local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local MatchService = require(script.Parent.MatchService)

-- Tag start/finish parts with CollectionService tags "StartLine" / "FinishLine"
-- and set a "StageId" string attribute on each to identify which stage they belong to.
-- Timing, matchmaking, and win-detection all live in MatchService; this module
-- is just the touch-detection layer.
--
-- Every StartLine feeds the same shared queue regardless of which stage it
-- belongs to -- MatchService rolls the actual stage at random once a
-- countdown begins, so a StartLine touch only means "I want to race."
local StageService = {}

local function getStageId(part: Instance): string?
	return part:GetAttribute("StageId")
end

local function onStartTouched(_part: Instance, hit: BasePart)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	if not player then
		return
	end

	MatchService.Enqueue(player)
end

local function onFinishTouched(part: Instance, hit: BasePart)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	local stageId = player and getStageId(part)
	if not player or not stageId then
		return
	end

	MatchService.PlayerReachedFinish(player, stageId)
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
