local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Stages = require(Shared.Stages)

-- Scenery flanking every course, so a stage reads as a PLACE rather than a
-- row of platforms in empty space.
--
-- StageDecorationService already gives each stage a per-weather palette, which
-- is what stopped all eight looking identical -- but a recoloured platform is
-- still just a platform. This is the other half: themed props standing beside
-- the course, on the void slab, framing the run.
--
-- TWO RULES GOVERN EVERYTHING HERE, and both exist because this is decoration
-- sitting next to a competitive timed course:
--
--   1. NOTHING IT CREATES MAY TOUCH GAMEPLAY. Every prop is CanCollide = false,
--      CanQuery = false and CanTouch = false. A collidable prop beside a
--      landing zone changes a jump; a touchable one can shadow a checkpoint's
--      own Touched (the same hazard StageDecorationService's beacon parts are
--      guarded against). Props are placed OUTSIDE the platform envelope with a
--      clearance margin, and a stage with no room simply gets no scenery.
--
--   2. IT LIVES OUTSIDE THE STAGES FOLDER. This one is not obvious and is the
--      reason for the separate top-level folder: StageBuilderService decides
--      where to build the Stage5-8 sky courses by taking the bounds of every
--      BasePart already under Workspace.Stages (see its existingBounds). Props
--      parented into a stage folder would enlarge those bounds and shove the
--      generated courses somewhere else -- a decoration pass silently moving
--      the courses the leaderboards are keyed to. Keeping scenery in its own
--      folder makes that impossible rather than merely unlikely.
--
-- The meshes themselves are MeshPart templates in ServerStorage.StageProps
-- (they have to be: MeshPart.MeshId cannot be assigned from a script at
-- runtime -- "lacking capability NotAccessible" -- so a prop can only be
-- CLONED from a template that already exists in the place). Everything about
-- WHERE they go is here, in code, where it can be read and changed.
local StageSceneryService = {}

local SCENERY_FOLDER_NAME = "StageScenery"

type Theme = {
	Prop: string,
	-- Height to scale the prop to. Bigger props for the sky courses, whose
	-- void slabs are ~110 studs across; the ground courses have as little as
	-- 14 studs of clearance either side and need to stay modest.
	Height: number,
	-- Studs between props along the course. Lower = denser.
	Spacing: number,
	-- Props sink this far into the void slab so they read as growing out of it
	-- rather than resting on a surface.
	Bury: number,
}

local THEMES: { [string]: Theme } = {
	Sunny = { Prop = "Tree", Height = 17, Spacing = 34, Bury = 1 },
	Stormy = { Prop = "Spire", Height = 19, Spacing = 38, Bury = 1.5 },
	Night = { Prop = "Crystal", Height = 15, Spacing = 30, Bury = 1.5 },
	-- Windy's palette is pale ice-white (see StageDecorationService) and its
	-- course is exposed and high -- cloud banks suit it better than anything
	-- rooted, and it reuses the Cloudy prop rather than needing its own.
	Windy = { Prop = "Cloud", Height = 9, Spacing = 26, Bury = 0 },
	Cloudy = { Prop = "Cloud", Height = 11, Spacing = 30, Bury = 0 },
}

-- Gap between the edge of the platform envelope and the nearest edge of a
-- prop. Sized off a jump rather than by eye: StageLayout allows gaps up to
-- ~12 studs, so a racer can legitimately be a few studs off the deck mid-jump,
-- and scenery must never be what they see filling that space.
local COURSE_CLEARANCE = 5

-- A void slab this close to the baseplate means the course is a GROUND course
-- (Stage1-4 sit ~2 studs above it) rather than one of the sky courses, whose
-- slabs float 150-450 studs up with nothing underneath.
--
-- The distinction decides where props may stand, and it is the difference
-- between four decorated stages and four bare ones. A sky course has no
-- surface but its own slab, so props must fit ON it -- and they do, since
-- those slabs are ~110 studs across against a ~30-stud run. The ground courses
-- are the opposite: their slabs are only 10-15 studs wider than the run, so
-- nothing fits beside the course, but real ground stretches away in every
-- direction just below. So ground props stand on the BASEPLATE, ringed outside
-- the slab entirely -- which also puts them further from the run than the sky
-- props ever get, at no cost to how they read from a course only a few studs up.
local GROUND_SNAP = 20
-- How far past the slab edge a ground prop may stand. Wide enough to form a
-- treeline rather than a hedge pressed against the course.
local GROUND_MARGIN = 20

local function isPlatform(part: Instance): boolean
	return part:IsA("BasePart") and part.Name:match("^Platform") ~= nil
end

-- The course's platform envelope, ignoring the void slab (which is far wider
-- than the run and would swallow the measurement).
local function platformBounds(stageFolder: Instance): (Vector3?, Vector3?)
	local min, max
	for _, part in stageFolder:GetChildren() do
		if isPlatform(part) then
			local half = (part :: BasePart).Size / 2
			local low = (part :: BasePart).Position - half
			local high = (part :: BasePart).Position + half
			min = if min
				then Vector3.new(math.min(min.X, low.X), math.min(min.Y, low.Y), math.min(min.Z, low.Z))
				else low
			max = if max
				then Vector3.new(math.max(max.X, high.X), math.max(max.Y, high.Y), math.max(max.Z, high.Z))
				else high
		end
	end
	return min, max
end

local function findVoid(stageFolder: Instance): BasePart?
	for _, part in stageFolder:GetChildren() do
		if part:IsA("BasePart") and part.Name == "VoidZone" then
			return part
		end
	end
	return nil
end

-- One prop, cloned and planted. Returns nil rather than erroring if the
-- template is missing, so an incomplete ServerStorage costs the scenery and
-- nothing else.
local function plant(template: BasePart?, parent: Folder, position: Vector3, height: number, seed: number)
	if not template then
		return
	end
	local prop = template:Clone()

	-- Deterministic per position: the same stage decorates identically on every
	-- server, which matters because players compare runs against each other and
	-- a landmark that moves between servers is a landmark that misleads.
	local rng = Random.new(seed)
	local scale = (height / template.Size.Y) * (0.85 + rng:NextNumber() * 0.3)
	prop.Size = template.Size * scale
	prop.CFrame = CFrame.new(position) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)

	-- Re-asserted on the clone rather than trusted from the template: these
	-- four are the entire safety contract between decoration and gameplay.
	prop.Anchored = true
	prop.CanCollide = false
	prop.CanQuery = false
	prop.CanTouch = false
	prop.Parent = parent
	return prop
end

local function decorate(stage: Stages.StageInfo, stageFolder: Instance, root: Folder, props: Folder): number
	local theme = THEMES[stage.Weather]
	if not theme then
		return 0
	end
	local template = props:FindFirstChild(theme.Prop) :: BasePart?
	if not template then
		return 0
	end

	local min, max = platformBounds(stageFolder)
	local void = findVoid(stageFolder)
	if not min or not max or not void then
		return 0
	end

	-- Courses run along whichever horizontal axis they are longer on: Stage1
	-- and Stage2 run along Z, the rest along X. Deriving it beats hardcoding
	-- per stage, since Stage5-8 are generated and could be re-planned.
	local span = max - min
	local alongX = span.X >= span.Z

	local courseCentre = (min + max) / 2
	local halfAcross = (if alongX then span.Z else span.X) / 2
	local voidHalfAcross = (if alongX then void.Size.Z else void.Size.X) / 2
	local voidCentreAcross = if alongX then void.Position.Z else void.Position.X
	local courseCentreAcross = if alongX then courseCentre.Z else courseCentre.X

	local propHalf = math.max(template.Size.X, template.Size.Z) / 2 * (theme.Height / template.Size.Y)

	local slabTop = void.Position.Y + void.Size.Y / 2
	local baseplate = Workspace:FindFirstChild("Baseplate") :: BasePart?
	local groundTop = if baseplate then baseplate.Position.Y + baseplate.Size.Y / 2 else 0
	local onGround = (slabTop - groundTop) <= GROUND_SNAP
	local surfaceY = if onGround then groundTop else slabTop

	local folder = Instance.new("Folder")
	folder.Name = stage.Id
	folder.Parent = root

	local alongMin = if alongX then min.X else min.Z
	local alongMax = if alongX then max.X else max.Z
	local placed = 0

	for _, side in { -1, 1 } do
		-- The band this side's props may stand in: nearest they may be without
		-- crowding the run, furthest they may be while still on a surface.
		local inner, outer
		if onGround then
			-- Clear of the slab entirely, out onto the baseplate. A prop
			-- straddling the slab edge would clip through it.
			inner = voidCentreAcross + side * (voidHalfAcross + propHalf + 2)
			outer = voidCentreAcross + side * (voidHalfAcross + propHalf + GROUND_MARGIN)
		else
			inner = courseCentreAcross + side * (halfAcross + COURSE_CLEARANCE + propHalf)
			outer = voidCentreAcross + side * (voidHalfAcross - propHalf)
		end
		-- If the near limit is already past the far one there is no room on
		-- this side, and nothing is placed -- the correct outcome, not a failure.
		if (outer - inner) * side < 0 then
			continue
		end

		local across = inner + (outer - inner) * 0.55
		-- Offset every other side by half a step so the two rows interleave
		-- rather than forming gates the course runs through.
		local offset = if side < 0 then theme.Spacing / 2 else 0
		local at = alongMin + offset
		while at <= alongMax do
			local position = if alongX
				then Vector3.new(at, surfaceY + theme.Height / 2 - theme.Bury, across)
				else Vector3.new(across, surfaceY + theme.Height / 2 - theme.Bury, at)
			local seed = math.floor(math.abs(at) * 3 + math.abs(across) * 7 + (if side < 0 then 991 else 17))
			if plant(template, folder, position, theme.Height, seed) then
				placed += 1
			end
			at += theme.Spacing
		end
	end

	return placed
end

-- Start, not Init, and deliberately so.
--
-- This measures two things another service is still changing during the Init
-- pass: StageEndpointService reshapes the start/finish pads and then EXTENDS
-- the void slab out underneath them, and the slab's width is exactly what
-- decides how far out a prop may stand. Running in Init would race it and
-- measure a slab that is about to grow. Loader calls every Init before any
-- Start, so this is the first moment the stages are finished being built,
-- themed and resized. (StageBuilderService's own build is earlier still --
-- require time -- so Stage5-8 exist well before either pass.)
function StageSceneryService.Start()
	local props = ServerStorage:FindFirstChild("StageProps")
	if not props then
		-- The templates live in the .rbxl. Without them there is simply no
		-- scenery; every stage still builds, themes and plays exactly as before.
		return
	end

	local stagesFolder = Workspace:FindFirstChild("Stages")
	if not stagesFolder then
		return
	end

	-- Rebuilt from scratch each start, so re-running never doubles up.
	local existing = Workspace:FindFirstChild(SCENERY_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = SCENERY_FOLDER_NAME
	root.Parent = Workspace

	for _, stage in Stages do
		local stageFolder = stagesFolder:FindFirstChild(stage.Id)
		if stageFolder then
			decorate(stage, stageFolder, root, props)
		end
	end
end

return StageSceneryService
