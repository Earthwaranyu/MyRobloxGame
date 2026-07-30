local Stages = require(script.Parent.Stages)
local Constants = require(script.Parent.Constants)

-- The COURSE PLAN for every generated stage (Stage5+ -- see Stages.luau's
-- `Generated` flag). Stage1-4 were drawn by hand in Studio and live in the
-- .rbxl; this is the other half of that story, for the stages that are built
-- from code at server start (see StageBuilderService, which turns a plan into
-- actual parts).
--
-- Why a plan module at all, instead of just spawning parts in the service:
--
--   * It is PURE -- no Instance, no Vector3, no Workspace -- so tests/run.sh
--     can check the geometry headlessly. That matters more here than it looks:
--     an unclearable gap is a stage nobody can finish, and finding that out
--     needs a Studio session per stage otherwise. See tests/spec.luau.
--   * It is DETERMINISTIC. Every server builds byte-identical courses, which
--     is what makes the per-stage top-100 boards (LeaderboardService) mean
--     anything -- times are only comparable if everyone ran the same course.
--     Hence the sine-driven weave below rather than a Random: not because a
--     seeded Random couldn't be deterministic, but because a rhythm plays
--     better than a scatter and reads honestly at a glance.
--
-- Everything is planned in the course's OWN space: the start pad sits at
-- x = 0 with its top surface at y = 0, and the course runs toward +x. The
-- service translates the whole thing to wherever the stage actually lives.
local StageLayout = {}

export type PartPlan = {
	Name: string,
	-- Centre of the part, in course space.
	X: number,
	Y: number,
	Z: number,
	SizeX: number,
	SizeY: number,
	SizeZ: number,
}

export type CoursePlan = {
	-- In running order: Platform_Start, Platform_1 .. Platform_N,
	-- Platform_Finish. BotService walks this exact chain by NAME, so the
	-- numbering has to stay contiguous and the order has to match the
	-- geometry -- see the naming note on buildPlatforms.
	Platforms: { PartPlan },
	Checkpoints: { PartPlan },
	Finish: PartPlan,
	Void: PartPlan,
	Spawn: PartPlan,
}

-- Roblox defaults, and the reason MaxJumpGap can be trusted: nothing in this
-- codebase changes either. Gravity is untouched in default.project.json, and
-- MovementService only ever writes WalkSpeed, never JumpPower.
local GRAVITY = 196.2
local JUMP_POWER = 50

-- The furthest a SPRINTING player can jump while climbing (or dropping)
-- `rise` studs, from the projectile solution: the jump is a plain ballistic
-- arc, so the honest way to size a gap is to solve for it rather than to
-- guess and playtest. Both roots of (g/2)t^2 - vt + rise = 0 pass through the
-- target height; the later one is the descending pass, which is the landing.
--
-- Sanity values at the shipped constants (v=50, g=196.2, sprint=24):
--   level ground  12.2 studs
--   +3 climb      10.6
--   -3 drop       13.5
-- Which is why a stage's gaps cannot simply be "bigger on Hard" -- 14 studs
-- is not a hard jump, it is an impossible one.
function StageLayout.MaxJumpGap(rise: number): number
	local discriminant = JUMP_POWER * JUMP_POWER - 2 * GRAVITY * rise
	if discriminant <= 0 then
		return 0 -- higher than the jump reaches at all
	end
	local airtime = (JUMP_POWER + math.sqrt(discriminant)) / GRAVITY
	return Constants.SprintSpeed * airtime
end

-- Every planned jump is held to this fraction of what the arc can actually
-- do. The margin is not politeness: a player arrives at a takeoff edge with
-- whatever speed they have (BotService's bots inset themselves 0.6 studs from
-- the edge, a human may be mid-turn or walking rather than sprinting), and a
-- gap sized at exactly 100% is only clearable from a perfect sprint off the
-- very lip.
local JUMP_SAFETY = 0.8
-- Lateral offset is spent out of the same budget (see planStep), but a jump
-- that is mostly sideways stops reading as "forward down the course", so the
-- weave never eats more than this share of it.
local MAX_LATERAL_SHARE = 0.7
-- Platforms must never end up touching, whatever the budget maths says.
local MIN_CLEARANCE = 3

type Tuning = {
	Count: number, -- platforms INCLUDING start and finish
	PadX: number, -- platform depth, along the course
	PadZ: number, -- platform width, across it
	Gap: number, -- edge-to-edge jump distance, before the physics clamp
	Weave: number, -- lateral amplitude
	Rise: number, -- vertical amplitude
	Checkpoints: number,
}

-- Difficulty is expressed as four dials at once -- more jumps, smaller
-- targets, longer gaps, more height change -- because any one of them alone
-- just makes a stage tedious rather than harder. Counts are in line with the
-- hand-built stages (Stage2 has 14 platforms, Stage3 has 16), so a generated
-- course takes about as long to run as an authored one.
local TUNING: { [string]: Tuning } = {
	Easy = { Count = 11, PadX = 16, PadZ = 14, Gap = 7, Weave = 7, Rise = 1.2, Checkpoints = 2 },
	Medium = { Count = 14, PadX = 13, PadZ = 12, Gap = 9, Weave = 10, Rise = 2, Checkpoints = 3 },
	Hard = { Count = 17, PadX = 10, PadZ = 10, Gap = 10.5, Weave = 13, Rise = 3, Checkpoints = 4 },
}

-- The gimmick is part of the difficulty, so the base tuning is adjusted for
-- whichever one a stage carries (StageGimmickService bolts it onto every
-- OTHER platform, never the first or last).
local function applyGimmick(tuning: Tuning, gimmick: string): Tuning
	local adjusted = table.clone(tuning)
	if gimmick == "Speed" then
		-- The strips boost to 42 studs/s and the boost outlives the platform
		-- you picked it up on, so these pads are longer along the course:
		-- somewhere to land after a boosted jump, instead of skidding off the
		-- far edge (the overshoot that MatchService's fall watchdog exists to
		-- catch).
		adjusted.PadX = tuning.PadX * 1.5
	elseif gimmick == "Moving" then
		-- A sliding platform is up to 0.6 * its smaller side off-centre when
		-- you arrive, so the slide IS the lateral challenge -- stacking a
		-- weave on top of it would just be two unrelated aims at once. Gaps
		-- shrink to leave room in the budget for a target that has drifted.
		adjusted.Weave = 0
		adjusted.Gap = tuning.Gap * 0.8
	elseif gimmick == "Vanishing" then
		-- Most jumps here start from a standstill, waiting for the next
		-- platform to come back, so there is no run-up to spend.
		adjusted.Gap = tuning.Gap * 0.9
	end
	return adjusted
end

-- Start and finish are oversized on every stage, for reasons that have
-- nothing to do with difficulty: MatchService fits the whole starting field
-- onto the start pad (buildStartGrid measures the pad and spreads racers
-- backwards across it -- 8 racers need real width and depth or they spend the
-- countdown falling off), and the finish has to be somewhere a player still
-- carrying a speed boost can actually stop.
local START_PAD_X = 30
local START_PAD_Z = 28
local FINISH_PAD_X = 26
local FINISH_PAD_Z = 22
local PAD_THICKNESS = 2

-- Two different irrational-ish frequencies so the weave and the climb never
-- line up into one long diagonal ramp -- the course should turn and rise on
-- different beats.
local WEAVE_FREQUENCY = 1.35
local WEAVE_PHASE = 0.7
local RISE_FREQUENCY = 0.9

local function platformName(index: number, count: number): string
	if index == 1 then
		return "Platform_Start"
	elseif index == count then
		return "Platform_Finish"
	end
	-- Platform_1 .. Platform_(count-2). BotService discovers waypoints by
	-- counting up from Platform_1 until one is missing, so a gap in this
	-- numbering silently truncates the bots' route at the hole.
	return "Platform_" .. tostring(index - 1)
end

local function buildPlatforms(tuning: Tuning, count: number): { PartPlan }
	local platforms: { PartPlan } = {}

	local x, y, z = 0, 0, 0
	for index = 1, count do
		local isStart = index == 1
		local isFinish = index == count
		local sizeX = if isStart then START_PAD_X elseif isFinish then FINISH_PAD_X else tuning.PadX
		local sizeZ = if isStart then START_PAD_Z elseif isFinish then FINISH_PAD_Z else tuning.PadZ

		if index > 1 then
			local previous = platforms[index - 1]

			-- Height first: the climb decides how far the jump can reach, so
			-- it has to be known before the gap is spent. The start pad is
			-- level (index 1 -> rise 0) and the finish is deliberately a step
			-- DOWN, which is the most forgiving way to arrive somewhere you
			-- are supposed to stop.
			local rise = if isFinish then -tuning.Rise else tuning.Rise * math.sin(index * RISE_FREQUENCY)
			local budget = math.min(tuning.Gap, StageLayout.MaxJumpGap(rise) * JUMP_SAFETY)

			-- Then the weave, out of the same budget: the real jump is the
			-- straight line, so a sideways step is distance NOT available
			-- forwards. Clamping the per-step lateral move (rather than the
			-- absolute weave) is what keeps that true -- the amplitude below
			-- is a target the course drifts toward, not a promise.
			local lateralLimit = budget * MAX_LATERAL_SHARE
			local desiredZ = tuning.Weave * math.sin(index * WEAVE_FREQUENCY + WEAVE_PHASE)
			local lateral = math.clamp(desiredZ - z, -lateralLimit, lateralLimit)

			-- Pythagoras on the remaining budget: forward clearance is
			-- whatever is left once the sideways part is paid for.
			local forward = math.max(MIN_CLEARANCE, math.sqrt(math.max(0, budget * budget - lateral * lateral)))

			x += previous.SizeX / 2 + forward + sizeX / 2
			y += rise
			z += lateral
		end

		table.insert(platforms, {
			Name = platformName(index, count),
			X = x,
			-- Y is the TOP surface everywhere else in this module (checkpoints
			-- and the finish banner sit on it), so the part centre drops by
			-- half the slab.
			Y = y - PAD_THICKNESS / 2,
			Z = z,
			SizeX = sizeX,
			SizeY = PAD_THICKNESS,
			SizeZ = sizeZ,
		})
	end

	return platforms
end

local CHECKPOINT_SIZE = 5
local CHECKPOINT_THICKNESS = 0.4

-- Checkpoints go on ODD platform-list indices, which is not cosmetic:
-- StageGimmickService targets every other platform starting at list index 2,
-- so the EVEN ones are the bouncing / sliding / vanishing ones. A checkpoint
-- pad on a platform that fades out and drops away would be a save point you
-- cannot reach, and one sharing a platform with a bounce pad would be buried
-- under it.
local function nearestOddIndex(target: number, count: number): number
	local odd = math.floor((target - 1) / 2 + 0.5) * 2 + 1
	return math.clamp(odd, 3, count - 2)
end

local function buildCheckpoints(platforms: { PartPlan }, wanted: number): { PartPlan }
	local checkpoints: { PartPlan } = {}
	local count = #platforms
	local used: { [number]: boolean } = {}

	for k = 1, wanted do
		local index = nearestOddIndex((k / (wanted + 1)) * count, count)
		if not used[index] then
			used[index] = true
			local platform = platforms[index]
			table.insert(checkpoints, {
				-- Checkpoint_1 upward, in course order. StageService reads
				-- the tag rather than the name, so this numbering is for
				-- whoever opens the Explorer, not for the game.
				Name = "Checkpoint_" .. tostring(#checkpoints + 1),
				X = platform.X,
				Y = platform.Y + platform.SizeY / 2 + CHECKPOINT_THICKNESS / 2,
				Z = platform.Z,
				SizeX = CHECKPOINT_SIZE,
				SizeY = CHECKPOINT_THICKNESS,
				SizeZ = CHECKPOINT_SIZE,
			})
		end
	end

	return checkpoints
end

-- Tall enough that no arc clears it: a player can arrive on the finish pad
-- from a bounce pad or a speed strip well above head height, and the banner
-- is what MatchService's win detection is bound to. StageService's swept
-- raycast is the backstop for the rest.
local FINISH_BANNER_HEIGHT = 16
local FINISH_BANNER_THICKNESS = 0.6
-- Just short of the pad's full width, so the banner reads as sitting on the
-- pad rather than as a wall of the same size floating at its edge.
local FINISH_BANNER_WIDTH_FACTOR = 0.95

-- Across the NEAR edge of the finish pad, not its middle: landing anywhere on
-- the pad means having crossed its near edge, whereas a banner in the centre
-- is one a short landing never touches.
local function buildFinish(platforms: { PartPlan }): PartPlan
	local finish = platforms[#platforms]
	return {
		Name = "FinishLine",
		X = finish.X - finish.SizeX / 2 + FINISH_BANNER_THICKNESS / 2,
		Y = finish.Y + finish.SizeY / 2 + FINISH_BANNER_HEIGHT / 2,
		Z = finish.Z,
		SizeX = FINISH_BANNER_THICKNESS,
		SizeY = FINISH_BANNER_HEIGHT,
		SizeZ = finish.SizeZ * FINISH_BANNER_WIDTH_FACTOR,
	}
end

-- The endpoint convention, in one place, because the hand-built stages are
-- held to the same numbers (StageEndpointService) and two copies of "16 studs
-- tall" would drift the moment either was tuned.
--
-- The pad sizes are in here for the same reason the banner is: Stage1-4 were
-- drawn with 7-9 stud start pads, which is a third of what a full field needs
-- to stand on, so bringing their start and finish up to this convention means
-- reshaping those pads to exactly what buildPlatforms gives Stage5-8.
StageLayout.Endpoint = {
	StartPadAlong = START_PAD_X,
	StartPadAcross = START_PAD_Z,
	FinishPadAlong = FINISH_PAD_X,
	FinishPadAcross = FINISH_PAD_Z,
	PadThickness = PAD_THICKNESS,
	BannerHeight = FINISH_BANNER_HEIGHT,
	BannerThickness = FINISH_BANNER_THICKNESS,
	BannerWidthFactor = FINISH_BANNER_WIDTH_FACTOR,
}

-- How far under the lowest platform the void trigger hangs. It only has to be
-- unmistakably "off the course": MatchService's altitude watchdog fires 1 stud
-- below the lowest standable surface and checks 6-7 times a second, so a
-- missed jump is recovered long before the slab is reached. The slab stays as
-- the instant-touch path (and, on these sky courses, as the visual floor).
local VOID_DROP = 35
local VOID_THICKNESS = 4
-- Generous ahead of the finish because overshooting it is a real outcome on a
-- Speed stage, and comfortably wide either side of the weave.
local VOID_MARGIN_BEHIND = 30
local VOID_MARGIN_AHEAD = 60
local VOID_MARGIN_SIDE = 40

local function buildVoid(platforms: { PartPlan }): PartPlan
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local lowestY = math.huge

	for _, platform in platforms do
		minX = math.min(minX, platform.X - platform.SizeX / 2)
		maxX = math.max(maxX, platform.X + platform.SizeX / 2)
		minZ = math.min(minZ, platform.Z - platform.SizeZ / 2)
		maxZ = math.max(maxZ, platform.Z + platform.SizeZ / 2)
		lowestY = math.min(lowestY, platform.Y - platform.SizeY / 2)
	end

	minX -= VOID_MARGIN_BEHIND
	maxX += VOID_MARGIN_AHEAD
	minZ -= VOID_MARGIN_SIDE
	maxZ += VOID_MARGIN_SIDE

	return {
		Name = "VoidZone",
		X = (minX + maxX) / 2,
		Y = lowestY - VOID_DROP - VOID_THICKNESS / 2,
		Z = (minZ + maxZ) / 2,
		SizeX = maxX - minX,
		SizeY = VOID_THICKNESS,
		SizeZ = maxZ - minZ,
	}
end

-- The `<StageId>Spawn` marker MatchService looks up by name. Its SIZE is the
-- start grid (buildStartGrid measures this part, not the platform, and builds
-- rows backwards from it in its own space), so it is deliberately most of the
-- start pad rather than a point: the pad's whole width is available across,
-- and half its depth behind.
local SPAWN_PAD_INSET = 0.9

-- Size of the spawn marker for a start pad, in the marker's OWN space --
-- returned as (across the course, along it).
--
-- The two axes are swapped relative to the pad, which is not a typo: the
-- marker is rotated to FACE down the course (the start grid is laid out in the
-- marker's own space, and only a marker that faces the right way spreads the
-- field across the pad instead of along it), and Size is local. So local X --
-- the axis buildStartGrid spreads columns along -- is the pad's across-course
-- side, and local Z -- the axis it builds rows BACKWARDS on -- is the pad's
-- along-course side.
--
-- `depthBehind` is how much pad there actually is behind the marker, which is
-- half the pad for a centred marker and less for one sitting further back.
-- Rows are laid out over half the local Z size, so capping that at twice the
-- depth behind is what keeps the back row on the pad -- the case that matters
-- for the hand-built stages, where the marker is wherever somebody dragged it
-- (see StageEndpointService, which normalises those without moving them).
function StageLayout.SpawnMarkerSize(padAcross: number, padAlong: number, depthBehind: number): (number, number)
	local across = padAcross * SPAWN_PAD_INSET
	local along = math.min(padAlong * SPAWN_PAD_INSET, math.max(0, depthBehind) * 2)
	return across, along
end

local function buildSpawn(stageId: string, platforms: { PartPlan }): PartPlan
	local start = platforms[1]
	-- Centred on the pad, so the depth behind it is half the pad.
	local across, along = StageLayout.SpawnMarkerSize(start.SizeZ, start.SizeX, start.SizeX / 2)
	return {
		Name = stageId .. "Spawn",
		X = start.X,
		Y = start.Y + start.SizeY / 2,
		Z = start.Z,
		SizeX = across,
		SizeY = 1,
		SizeZ = along,
	}
end

export type Extent = {
	MinX: number,
	MaxX: number,
	MinY: number,
	MaxY: number,
	MinZ: number,
	MaxZ: number,
}

-- Bounding box of everything a plan contains, in course space. The Y range is
-- the one that earns its keep: a course is much taller than its platforms
-- suggest (the void slab hangs 35 studs under the lowest deck and the finish
-- banner stands 16 above the highest), so a caller stacking courses in the sky
-- has to stack them by their real extent. Doing that with a constant is how
-- Stage5's banner and Stage6's void slab ended up 1 stud apart.
function StageLayout.Extent(plan: CoursePlan): Extent
	local extent: Extent = {
		MinX = math.huge,
		MaxX = -math.huge,
		MinY = math.huge,
		MaxY = -math.huge,
		MinZ = math.huge,
		MaxZ = -math.huge,
	}

	local function include(part: PartPlan)
		extent.MinX = math.min(extent.MinX, part.X - part.SizeX / 2)
		extent.MaxX = math.max(extent.MaxX, part.X + part.SizeX / 2)
		extent.MinY = math.min(extent.MinY, part.Y - part.SizeY / 2)
		extent.MaxY = math.max(extent.MaxY, part.Y + part.SizeY / 2)
		extent.MinZ = math.min(extent.MinZ, part.Z - part.SizeZ / 2)
		extent.MaxZ = math.max(extent.MaxZ, part.Z + part.SizeZ / 2)
	end

	for _, platform in plan.Platforms do
		include(platform)
	end
	for _, checkpoint in plan.Checkpoints do
		include(checkpoint)
	end
	include(plan.Finish)
	include(plan.Void)
	include(plan.Spawn)

	return extent
end

function StageLayout.Build(stage: Stages.StageInfo): CoursePlan
	local tuning = applyGimmick(TUNING[stage.Difficulty] or TUNING.Medium, stage.Gimmick)
	local platforms = buildPlatforms(tuning, tuning.Count)

	return {
		Platforms = platforms,
		Checkpoints = buildCheckpoints(platforms, tuning.Checkpoints),
		Finish = buildFinish(platforms),
		Void = buildVoid(platforms),
		Spawn = buildSpawn(stage.Id, platforms),
	}
end

return StageLayout
