local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local StageLayout = require(Shared.StageLayout)
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

-- A checkpoint pad is a 0.3-stud slab covering just over half its platform's
-- deck, and until now that slab WAS the trigger -- so a checkpoint only counted
-- if you physically brushed it. That fails in the two situations a save point
-- matters most:
--
--   * You arrive with LIFT and fly over it. Meteor Dash is 85 studs/s forward
--     with a 35 stud/s upward kick, so it crosses a checkpoint platform several
--     studs above the deck; bounce pads and speed strips do the same. You pass
--     the checkpoint, nothing records it, and the next fall sends you back to
--     wherever you last actually touched -- the start pad, if you had skipped
--     the earlier ones too. That is the reported bug.
--   * You land on the platform but off the pad. Real on the GENERATED stages,
--     where a 5-stud pad sits on a deck up to 16x14 -- measured in Studio, a
--     character standing 6 studs off centre touches nothing at all. Stage1-4's
--     decks are too small for this to bite: a character is wider than the ring
--     of deck left around the pad.
--
-- The fix is a capture volume: an invisible box over the checkpoint's whole
-- platform, tall enough that no launch clears it, which reports the PAD as the
-- checkpoint. Being anywhere on or above the platform is what "reached this
-- checkpoint" should have meant all along. The height is derived rather than
-- picked -- see StageLayout.Checkpoint, which sizes it off the bounce pad and
-- Meteor arcs and is held to them by tests/spec.luau.
--
-- Deliberately NOT added to the swept-raycast filter. The sweep exists for
-- triggers thin enough to tunnel through; at 1.4 studs of travel per frame even
-- Meteor cannot cross a box this tall without a Touched, and a box this large in
-- the filter would start winning the sweep's nearest-hit test against the things
-- that genuinely need it.
local CAPTURE_HEIGHT = StageLayout.Checkpoint.CaptureHeight
-- Fallback footprint when a pad has no platform under it (a checkpoint left
-- floating in the .rbxl), as a multiple of the pad. Keeps such a checkpoint
-- catchable instead of silently keeping the old pad-only behaviour.
local CAPTURE_PAD_FACTOR = 1.4

-- The platform a pad sits on, by footprint rather than by name: it is what the
-- volume has to cover, and matching on "^Platform" alone would pick whichever
-- one GetChildren returned first.
local function platformUnder(pad: BasePart): BasePart?
	local stageFolder = pad.Parent
	if not stageFolder then
		return nil
	end

	local best, bestDrop = nil :: BasePart?, math.huge
	for _, part in stageFolder:GetChildren() do
		if part:IsA("BasePart") and part.Name:match("^Platform") then
			local offset = part.CFrame:PointToObjectSpace(pad.Position)
			if math.abs(offset.X) <= part.Size.X / 2 + 1 and math.abs(offset.Z) <= part.Size.Z / 2 + 1 then
				-- The nearest deck BELOW the pad, so a pad over a stack of
				-- platforms binds to the one it is actually resting on.
				local drop = math.abs(pad.Position.Y - (part.Position.Y + part.Size.Y / 2))
				if drop < bestDrop then
					best, bestDrop = part, drop
				end
			end
		end
	end
	return best
end

local function addCaptureVolume(pad: BasePart)
	if pad:FindFirstChild("CaptureVolume") then
		return -- already built; safe to re-run over a stage
	end

	local platform = platformUnder(pad)
	local footprint = if platform
		then Vector2.new(platform.Size.X, platform.Size.Z)
		else Vector2.new(pad.Size.X * CAPTURE_PAD_FACTOR, pad.Size.Z * CAPTURE_PAD_FACTOR)
	-- Rises from the deck the pad rests on, not from the pad's own centre, so
	-- the full height is available above the surface a racer crosses.
	local deckY = if platform then platform.Position.Y + platform.Size.Y / 2 else pad.Position.Y

	local volume = Instance.new("Part")
	volume.Name = "CaptureVolume"
	volume.Anchored = true
	volume.Size = Vector3.new(footprint.X, CAPTURE_HEIGHT, footprint.Y)
	-- Aligned to the PLATFORM's rotation where there is one, so the box covers a
	-- rotated deck instead of a world-axis box over part of it.
	local orientation = if platform then platform.CFrame.Rotation else pad.CFrame.Rotation
	volume.CFrame = CFrame.new(Vector3.new(pad.Position.X, deckY + CAPTURE_HEIGHT / 2, pad.Position.Z)) * orientation
	volume.Transparency = 1
	-- Must never affect the run it is measuring: a solid box over a platform
	-- would be a wall, and a queryable one would put an invisible surface under
	-- every raycast (including the sweep's) on this platform.
	volume.CanCollide = false
	volume.CanTouch = true
	volume.CanQuery = false
	volume.CastShadow = false
	volume.Parent = pad

	-- Reports the PAD, not itself: MatchService stores the touched part's CFrame
	-- as the recovery point, and recovering to the middle of a 16-stud box would
	-- drop the player in from 8 studs up.
	volume.Touched:Connect(function(hit)
		onCheckpointTouched(pad, hit)
	end)
end

local function captureAll()
	for _, pad in CollectionService:GetTagged("Checkpoint") do
		if pad:IsA("BasePart") then
			addCaptureVolume(pad)
		end
	end
	CollectionService:GetInstanceAddedSignal("Checkpoint"):Connect(function(pad)
		if pad:IsA("BasePart") then
			addCaptureVolume(pad)
		end
	end)
end

function StageService.Init()
	bindAll("StartLine", onStartTouched)
	bindAll("FinishLine", onFinishTouched)
	bindAll("Checkpoint", onCheckpointTouched)
	bindAll("VoidZone", onVoidTouched)
	-- After bindAll, so a checkpoint that arrives while this runs is bound by the
	-- tag signal above before it can be handed a volume.
	captureAll()

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
