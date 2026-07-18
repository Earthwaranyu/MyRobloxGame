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
--
-- "Checkpoint" and "VoidZone" tagged parts (also carrying a "StageId"
-- attribute) work the same way: touching a Checkpoint updates where a fall
-- recovers you to, touching a VoidZone (a big trigger under each course,
-- catching anyone who misses a jump) teleports you back there.
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

local function onCheckpointTouched(part: Instance, hit: BasePart)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	local stageId = player and getStageId(part)
	if not player or not stageId or not part:IsA("BasePart") then
		return
	end

	MatchService.PlayerReachedCheckpoint(player, stageId, part.CFrame)
end

local function onVoidTouched(part: Instance, hit: BasePart)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	local stageId = player and getStageId(part)
	if not player or not stageId then
		return
	end

	MatchService.PlayerFellOff(player, stageId)
end

local function bindTouch(part: Instance, handler: (Instance, BasePart) -> ())
	if part:IsA("BasePart") then
		part.Touched:Connect(function(hit)
			handler(part, hit)
		end)
	end
end

local function bindAll(tagName: string, handler: (Instance, BasePart) -> ())
	for _, part in CollectionService:GetTagged(tagName) do
		bindTouch(part, handler)
	end
	CollectionService:GetInstanceAddedSignal(tagName):Connect(function(part)
		bindTouch(part, handler)
	end)
end

function StageService.Init()
	bindAll("StartLine", onStartTouched)
	bindAll("FinishLine", onFinishTouched)
	bindAll("Checkpoint", onCheckpointTouched)
	bindAll("VoidZone", onVoidTouched)
end

return StageService
