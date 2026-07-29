local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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

-- Touched is not sufficient on its own for the parts that decide progress.
--
-- It reports contact discovered during a physics step, so a character moving
-- fast enough to be on one side of a thin trigger at one step and past it at
-- the next can cross without ever touching it. Dash covers 55 studs/s and
-- Meteor 85; worse, Blink TELEPORTS 24 studs, so there is no intermediate
-- position for Touched to catch at any framerate. The symptom is a checkpoint
-- that silently doesn't register -- or, far worse, a missed FinishLine.
--
-- So each frame we also sweep the segment the root actually travelled and see
-- if it passed through a trigger. Touched still handles the ordinary case
-- (including brushing a checkpoint the root itself never entered); this only
-- adds the crossings it structurally cannot see. Both paths are safe to fire
-- together: PlayerReachedCheckpoint just reassigns the recovery CFrame, and
-- MatchService guards the finish against being counted twice.
--
-- StartLine and VoidZone are deliberately excluded. StartLine means "I want to
-- race" rather than progress, and VoidZone parts are huge -- neither is
-- tunnelable, and sweeping StartLine would queue people who dashed past it.
local SWEPT_TAGS = { "Checkpoint", "FinishLine" }
-- Below this a frame's movement is ordinary walking, already covered by
-- Touched, and not worth a raycast per player per frame.
local MIN_SWEEP_STUDS = 0.5
-- Above this the character did not TRAVEL the segment, it was teleported along
-- it -- race start, fall recovery, or a stage change. Sweeping a teleport fires
-- every trigger on the straight line between the two points, which in the worst
-- case hands somebody the finish line during the race-start teleport. Blink is
-- the longest legitimate instantaneous move at 24 studs, so 40 clears it
-- comfortably while staying far below any teleport in the game.
local MAX_SWEEP_STUDS = 40

local sweepParams = RaycastParams.new()
sweepParams.FilterType = Enum.RaycastFilterType.Include

local lastRootPosition: { [number]: Vector3 } = {}

local function refreshSweepFilter()
	local parts = {}
	for _, tag in SWEPT_TAGS do
		for _, part in CollectionService:GetTagged(tag) do
			if part:IsA("BasePart") then
				-- Triggers are non-collidable, which raycasts don't mind, but a
				-- part with CanQuery off is invisible to them entirely -- and
				-- being invisible to queries is an easy thing to set on a
				-- trigger without realising it now matters.
				part.CanQuery = true
				table.insert(parts, part)
			end
		end
	end
	sweepParams.FilterDescendantsInstances = parts
end

local function sweepPlayer(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		lastRootPosition[player.UserId] = nil
		return
	end

	local current = root.Position
	local previous = lastRootPosition[player.UserId]
	lastRootPosition[player.UserId] = current
	-- No previous sample means they just spawned or teleported; the gap isn't a
	-- path they travelled, so sweeping it would fire triggers along a line they
	-- were never on.
	if not previous then
		return
	end

	local delta = current - previous
	local travelled = delta.Magnitude
	if travelled < MIN_SWEEP_STUDS or travelled > MAX_SWEEP_STUDS then
		return
	end

	local result = Workspace:Raycast(previous, delta, sweepParams)
	if not result then
		return
	end

	-- Only the nearest trigger on the segment. Crossing two in one frame is
	-- possible in principle but the next frame picks up the second, and
	-- checkpoints are ordered along the course anyway.
	local part = result.Instance
	if CollectionService:HasTag(part, "FinishLine") then
		onFinishTouched(part, root)
	else
		onCheckpointTouched(part, root)
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

	refreshSweepFilter()
	for _, tag in SWEPT_TAGS do
		CollectionService:GetInstanceAddedSignal(tag):Connect(refreshSweepFilter)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(refreshSweepFilter)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastRootPosition[player.UserId] = nil
	end)

	RunService.Heartbeat:Connect(function()
		for _, player in Players:GetPlayers() do
			sweepPlayer(player)
		end
	end)
end

return StageService
