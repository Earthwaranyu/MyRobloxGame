local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Stages = require(Shared.Stages)
local StageLayout = require(Shared.StageLayout)

-- Builds the courses for every stage flagged `Generated` in Stages.luau
-- (Stage5-8) out of StageLayout's plan, following the same Workspace
-- conventions the hand-built Stage1-4 already follow -- so every service that
-- reads stage geometry keeps working without knowing which kind it is looking
-- at:
--
--   Workspace.Stages.<StageId>/
--     Platform_Start, Platform_1..N, Platform_Finish   BotService's waypoints
--     <StageId>Spawn                                   MatchService's start grid
--     Checkpoint_1..K   tag "Checkpoint"  + StageId    fall recovery
--     FinishLine        tag "FinishLine"  + StageId    win detection
--     VoidZone          tag "VoidZone"    + StageId    instant miss trigger
--
-- WHY GENERATED AT ALL: Stage1-4 are drawn by hand and stored in the .rbxl,
-- which is fine for four courses and does not scale -- geometry that lives in
-- the place file is invisible to git, cannot be reviewed, cannot be unit
-- tested, and only persists if somebody remembers to save Studio. Four more
-- courses in code cost nothing per stage after the first and are identical on
-- every server, which per-stage leaderboards need (see StageLayout).
--
-- They are NOT visible in Studio's Edit view, because this is a server
-- script: press Play and they appear under Workspace.Stages. Nothing here
-- needs saving -- it is rebuilt from scratch every server start.
local StageBuilderService = {}

-- Generated courses sit in the sky ABOVE the hand-built cluster rather than
-- beside it, for three reasons: the ground around the existing stages is
-- already crowded (a course is ~300 studs long and the Baseplate is only
-- 1000 wide), the lobby is down there and every VoidZone is enormous (see
-- MatchService.PlayerFellOff on lobby/void overlap), and a floating course is
-- what an obby looks like anyway.
--
-- Stacking is safe because falling off is caught by altitude, not by
-- geometry: MatchService's watchdog fires 1 stud below a stage's own lowest
-- platform, 6-7 times a second, so a racer who drops off Stage8 is recovered
-- within a stud or two -- long before they could reach Stage7's deck 60 studs
-- below.
local MIN_SKY_Y = 150
local SKY_CLEARANCE = 60 -- above the highest existing geometry
-- Air between one generated course's highest part and the next course's
-- lowest. Courses are stacked on their MEASURED extent rather than a fixed
-- rise per lane (see StageLayout.Extent): a course is ~58 studs tall once its
-- void slab and finish banner are counted, so a constant that looked like
-- plenty left Stage5's banner one stud under Stage6's slab.
local LANE_CLEARANCE = 40
local LANE_Z_SPACING = 90 -- lateral offset too, so the stack isn't one column

local PLATFORM_COLOR = Color3.fromRGB(150, 155, 165)
local PLATFORM_MATERIAL = Enum.Material.SmoothPlastic
local VOID_COLOR = Color3.fromRGB(120, 150, 190)
local VOID_TRANSPARENCY = 0.7
-- Gold, and the only part of a generated course that is emissive by default:
-- the finish is the one thing a racer should be able to pick out from the
-- start pad.
local FINISH_COLOR = Color3.fromRGB(255, 205, 70)
local CHECKPOINT_COLOR = Color3.fromRGB(70, 235, 130) -- matches StageDecorationService

local function makePart(plan: StageLayout.PartPlan, origin: Vector3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = plan.Name
	part.Anchored = true
	part.Size = Vector3.new(plan.SizeX, plan.SizeY, plan.SizeZ)
	part.Position = origin + Vector3.new(plan.X, plan.Y, plan.Z)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function buildPlatforms(plan: StageLayout.CoursePlan, origin: Vector3, folder: Folder)
	for _, platformPlan in plan.Platforms do
		local platform = makePart(platformPlan, origin, folder)
		-- Colour and material are overwritten a moment later by
		-- StageDecorationService's per-weather palette (it matches on the
		-- "^Platform" name). These are the fallback for a weather with no
		-- palette entry, so a new WeatherKind is a plain-looking stage rather
		-- than a broken one.
		platform.Color = PLATFORM_COLOR
		platform.Material = PLATFORM_MATERIAL
	end
end

local function buildCheckpoints(plan: StageLayout.CoursePlan, origin: Vector3, folder: Folder, stageId: string)
	for _, checkpointPlan in plan.Checkpoints do
		local checkpoint = makePart(checkpointPlan, origin, folder)
		checkpoint.Color = CHECKPOINT_COLOR
		checkpoint.Material = Enum.Material.Neon
		-- A trigger, not a step: 0.4 studs of collidable pad on top of a
		-- platform is exactly the kind of lip that eats a jump. Touched still
		-- fires on a non-collidable part.
		checkpoint.CanCollide = false
		checkpoint.CanTouch = true
		-- StageService's swept raycast needs to be able to see it (it sets
		-- this itself as a safeguard; set here too so the part is correct the
		-- moment it exists).
		checkpoint.CanQuery = true
		checkpoint:SetAttribute("StageId", stageId)
		CollectionService:AddTag(checkpoint, "Checkpoint")
	end
end

local function buildFinish(plan: StageLayout.CoursePlan, origin: Vector3, folder: Folder, stageId: string)
	local finish = makePart(plan.Finish, origin, folder)
	finish.Color = FINISH_COLOR
	finish.Material = Enum.Material.Neon
	finish.Transparency = 0.25
	-- Must never block the landing it is measuring.
	finish.CanCollide = false
	finish.CanTouch = true
	finish.CanQuery = true
	finish:SetAttribute("StageId", stageId)
	CollectionService:AddTag(finish, "FinishLine")
end

local function buildVoid(plan: StageLayout.CoursePlan, origin: Vector3, folder: Folder, stageId: string)
	local void = makePart(plan.Void, origin, folder)
	void.Color = VOID_COLOR
	void.Material = Enum.Material.SmoothPlastic
	void.Transparency = VOID_TRANSPARENCY
	void.CanCollide = false
	void.CanTouch = true
	-- Deliberately NOT queryable: it spans the entire course, so leaving it in
	-- raycast range would put a wall under every shot fired downward.
	void.CanQuery = false
	void:SetAttribute("StageId", stageId)
	CollectionService:AddTag(void, "VoidZone")
end

local function buildSpawn(plan: StageLayout.CoursePlan, origin: Vector3, folder: Folder)
	local spawn = makePart(plan.Spawn, origin, folder)
	-- Invisible and inert: it exists to be MEASURED (MatchService reads its
	-- size and CFrame to lay out the start grid), never to be stood on or
	-- touched. It would also drag the fall-floor calculation down to the start
	-- pad if it were collidable (getFallFloorY only counts collidable parts).
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanTouch = false
	spawn.CanQuery = false
	-- Rotation is the whole point of building this one as a CFrame: the start
	-- grid is laid out in the spawn part's OWN space and builds rows
	-- BACKWARDS, so the part has to face down the course (+X here) or the
	-- field spreads sideways off the pad.
	spawn.CFrame = CFrame.lookAt(spawn.Position, spawn.Position + Vector3.xAxis)
end

local function componentwise(a: Vector3, b: Vector3, pick: (number, number) -> number): Vector3
	return Vector3.new(pick(a.X, b.X), pick(a.Y, b.Y), pick(a.Z, b.Z))
end

-- Bounding box of whatever is already in Workspace.Stages, so the generated
-- courses can be placed clear of it without this module needing to know
-- anything about the hand-built geometry (which is edited in Studio and moves
-- around independently of this code -- hand-editing Stage1-4 moves the sky
-- courses with it, which is the point: they stay clear either way).
local function existingBounds(stagesFolder: Folder): (Vector3?, Vector3?)
	local min, max = nil :: Vector3?, nil :: Vector3?
	for _, descendant in stagesFolder:GetDescendants() do
		if descendant:IsA("BasePart") then
			local half = descendant.Size / 2
			local low = descendant.Position - half
			local high = descendant.Position + half
			min = if min then componentwise(min, low, math.min) else low
			max = if max then componentwise(max, high, math.max) else high
		end
	end
	return min, max
end

local function buildStage(stage: Stages.StageInfo, plan: StageLayout.CoursePlan, origin: Vector3, stagesFolder: Folder)
	local folder = Instance.new("Folder")
	folder.Name = stage.Id

	buildPlatforms(plan, origin, folder)
	buildCheckpoints(plan, origin, folder, stage.Id)
	buildFinish(plan, origin, folder, stage.Id)
	buildVoid(plan, origin, folder, stage.Id)
	buildSpawn(plan, origin, folder)

	-- Parented last, so no other service can observe a half-built course.
	-- Tags fire their added-signals immediately either way (StageService and
	-- StageDecorationService both listen), which is harmless: those handlers
	-- only ever touch the part they are handed.
	folder.Parent = stagesFolder
end

local function build()
	local stagesFolder = Workspace:FindFirstChild("Stages")
	if not stagesFolder or not stagesFolder:IsA("Folder") then
		stagesFolder = Instance.new("Folder")
		stagesFolder.Name = "Stages"
		stagesFolder.Parent = Workspace
	end

	local generated: { Stages.StageInfo } = {}
	for _, stage in Stages do
		if stage.Generated then
			-- Never overwrite geometry that already exists: a stage that got
			-- hand-built later should win over its generated plan, and this
			-- also makes the module safe to require twice.
			if stagesFolder:FindFirstChild(stage.Id) then
				warn(("StageBuilderService: %s already exists in Workspace.Stages, leaving it alone"):format(stage.Id))
			else
				table.insert(generated, stage)
			end
		end
	end

	local existingMin, existingMax = existingBounds(stagesFolder :: Folder)
	local baseY = math.max(MIN_SKY_Y, if existingMax then existingMax.Y + SKY_CLEARANCE else MIN_SKY_Y)
	-- Aligned with the existing cluster: same starting X, centred on its Z, so
	-- the whole set reads as one place seen from the lobby rather than four
	-- courses parked off in a corner.
	local baseX = if existingMin then existingMin.X else 0
	local centreZ = if existingMin and existingMax then (existingMin.Z + existingMax.Z) / 2 else 0

	-- Lowest free altitude, walked upward as each course is placed.
	local ceiling = baseY

	for index, stage in generated do
		local lane = index - 1
		local plan = StageLayout.Build(stage)
		local extent = StageLayout.Extent(plan)
		-- Lift the plan so its LOWEST part (the void slab, not the start pad)
		-- sits on the running ceiling.
		local originY = ceiling - extent.MinY
		local origin = Vector3.new(baseX, originY, centreZ + (lane - (#generated - 1) / 2) * LANE_Z_SPACING)

		-- One bad stage must not take the other three (or the server) with it:
		-- a stage listed in Stages.luau with no geometry behind it is a race
		-- nobody can start, so the failure is worth shouting about.
		local ok, err = pcall(buildStage, stage, plan, origin, stagesFolder :: Folder)
		if not ok then
			warn(("StageBuilderService: failed to build %s -- %s"):format(stage.Id, tostring(err)))
		end

		ceiling = originY + extent.MaxY + LANE_CLEARANCE
	end
end

-- Runs at REQUIRE time, not in Init(), and that ordering is load-bearing.
--
-- Loader.LoadAll requires every service first and only then calls their
-- Init()s, so building here is the one place guaranteed to finish before any
-- other service's Init runs. StageGimmickService in particular reads the
-- platforms of every stage exactly once, in its Init, with no
-- instance-added signal to catch later arrivals -- a course built after it
-- would have no bounce pads, no moving platforms, no gimmick at all. Init
-- order between siblings is whatever GetChildren happens to return, so it
-- cannot be relied on instead.
build()

function StageBuilderService.Init() end

return StageBuilderService
