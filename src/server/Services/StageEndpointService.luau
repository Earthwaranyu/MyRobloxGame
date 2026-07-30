local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Stages = require(Shared.Stages)
local StageLayout = require(Shared.StageLayout)

-- Brings the START and FINISH of the hand-built stages (Stage1-4, drawn in
-- Studio and stored in the .rbxl) up to the same convention StageBuilderService
-- builds Stage5-8 to, so all eight courses begin and end the same way:
--
--   * a start pad big enough to hold the whole field (30 x 28), with an
--     invisible `<StageId>Spawn` marker centred on it and FACING down the
--     course, so MatchService.buildStartGrid spreads racers across the pad and
--     builds its rows backwards along it
--   * a finish pad big enough to stop on (26 x 22), with a gold neon banner
--     standing across its NEAR edge, spanning its width, tall enough that no
--     arc clears it
--
-- WHAT WAS ACTUALLY WRONG WITH THEM, since "make them match" undersells it:
--
--   * The start pads are 7-9 studs square. A wave of 8 needs roughly 25 across
--     and 15 of depth behind the line, so the grid never fitted -- it fell back
--     on shrinking its spacing until the field stood inside each other.
--   * `<StageId>Spawn` was a small collidable pad floating a few studs BEHIND
--     the start pad, not a marker on it, so the field spent the countdown on a
--     6x6 island off the back of the course.
--   * Every one of those markers was left at yaw 0 while only Stage1 and 2 run
--     down +Z. Since the grid is laid out in the marker's own space, rows built
--     TOWARD the finish on Stage1/2 and columns spread ALONG the course on
--     Stage3/4 -- a real head start of up to a row per racer, on a game whose
--     whole point is a fair start.
--
-- WHAT THIS DELIBERATELY DOES NOT DO: change the course. Pads are only ever
-- GROWN, and always away from the run -- the start pad keeps its leading edge
-- and extends backwards, the finish pad keeps its leading edge and extends
-- forwards -- so no jump on any stage gets longer or shorter, and no platform
-- in between is touched. A pad already bigger than the convention keeps its
-- size.
--
-- Everything is measured off the geometry at run time rather than hard-coded,
-- because that geometry lives in the place file: it is edited in Studio, it can
-- be rotated, its courses do not run down the same world axis (none of the four
-- run down an exact axis), and it is not visible from here.
local StageEndpointService = {}

local FINISH_COLOR = Color3.fromRGB(255, 205, 70)
local FINISH_TRANSPARENCY = 0.25

-- The one definition of what a finish banner looks like. StageBuilderService
-- calls this too, so the generated and hand-built stages cannot drift apart.
function StageEndpointService.ApplyFinishStyle(banner: BasePart)
	banner.Color = FINISH_COLOR
	banner.Material = Enum.Material.Neon
	banner.Transparency = FINISH_TRANSPARENCY
	-- Must never block the landing it is measuring, must still register a
	-- touch, and must stay visible to StageService's swept raycast (which is
	-- what catches a racer crossing it faster than Touched can see).
	banner.CanCollide = false
	banner.CanTouch = true
	banner.CanQuery = true
end

-- Half-extent of a part along an arbitrary world axis. The general form (sum of
-- each local axis projected onto the target) rather than "just read Size.X",
-- because a hand-built pad may be rotated to any angle and a course may run
-- down any axis -- reading Size directly is only correct for an axis-aligned
-- pad on an axis-aligned course.
local function halfExtentAlong(part: BasePart, axis: Vector3): number
	local cframe, size = part.CFrame, part.Size
	return math.abs(cframe.RightVector:Dot(axis)) * size.X / 2
		+ math.abs(cframe.UpVector:Dot(axis)) * size.Y / 2
		+ math.abs(cframe.LookVector:Dot(axis)) * size.Z / 2
end

-- Which way the course runs, from the pad a racer starts on to the pad they
-- finish on. Flattened: a course that climbs still "runs" horizontally, and the
-- start grid and the banner are both horizontal layouts.
local function courseDirection(startPad: BasePart, finishPad: BasePart): Vector3?
	local delta = finishPad.Position - startPad.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 1 then
		return nil
	end
	return flat.Unit
end

local function acrossAxis(direction: Vector3): Vector3
	return Vector3.new(-direction.Z, 0, direction.X)
end

local function topSurfaceY(part: BasePart): number
	return part.Position.Y + halfExtentAlong(part, Vector3.yAxis)
end

-- Grows a pad to the convention while pinning ONE of its edges along the
-- course, which is the whole reason this is safe to run over authored geometry:
-- `keepEdge` is +1 to hold the far edge (the pad extends backwards, away from
-- the course) or -1 to hold the near edge (it extends forwards, past the end).
-- Either way the jump into or out of the pad is exactly the jump that was
-- drawn.
--
-- The pad is also re-aimed down the course, so its sides run with the run
-- rather than with the world axes -- the courses are a few degrees off true, so
-- an axis-aligned pad on one is a subtly crooked pad.
local function growPad(pad: BasePart, direction: Vector3, along: number, across: number, keepEdge: number)
	local side = acrossAxis(direction)
	-- Never shrink: a stage drawn with a bigger pad than the convention asks
	-- for has a reason of its own, and taking width away from a start grid is
	-- the one change here that could put a racer off an edge.
	local sizeAlong = math.max(along, halfExtentAlong(pad, direction) * 2)
	local sizeAcross = math.max(across, halfExtentAlong(pad, side) * 2)
	local thickness = halfExtentAlong(pad, Vector3.yAxis) * 2

	local pinnedEdge = pad.Position:Dot(direction) + keepEdge * halfExtentAlong(pad, direction)
	local centreAlong = pinnedEdge - keepEdge * sizeAlong / 2
	-- Across the course the pad stays centred where it was drawn, so a course
	-- that weaves keeps its line.
	local centreAcross = pad.Position:Dot(side)
	-- Deck height is preserved exactly: it is what every jump on the stage was
	-- drawn against, and what MatchService's fall watchdog measures from.
	local deckY = topSurfaceY(pad)

	local position = direction * centreAlong + side * centreAcross + Vector3.new(0, deckY - thickness / 2, 0)
	-- lookAt puts local -Z on the target, so local Z is the along-course axis
	-- and local X is across -- which is the order Size is written in below.
	pad.Size = Vector3.new(sizeAcross, thickness, sizeAlong)
	pad.CFrame = CFrame.lookAt(position, position + direction)
	pad.Anchored = true
end

-- Sizes, centres and aims the spawn marker on the start pad.
--
-- Centred rather than left where it was drawn: the authored markers sit off the
-- BACK of their pad entirely, so preserving their position would lay the grid
-- out over thin air. Centring moves the field 2-4 studs back on these stages --
-- the pad now reaches further back than the old marker did -- which is well
-- inside the noise of where in a grid slot a racer happens to stand.
local function normalizeSpawn(stageFolder: Instance, stageId: string, startPad: BasePart, direction: Vector3)
	local marker = stageFolder:FindFirstChild(stageId .. "Spawn")
	if marker and not marker:IsA("BasePart") then
		warn(("StageEndpointService: %sSpawn is a %s, not a part -- skipping"):format(stageId, marker.ClassName))
		return
	end

	local spawnPart = marker :: BasePart?
	if not spawnPart then
		spawnPart = Instance.new("Part")
		spawnPart.Name = stageId .. "Spawn"
		-- No marker at all means MatchService had no start grid for this stage
		-- and fell back to dropping the whole field on one CFrame, so this is
		-- worth saying out loud rather than silently fixing.
		warn(("StageEndpointService: %s had no spawn marker, creating one on its start pad"):format(stageId))
		spawnPart.Parent = stageFolder
	end

	local side = acrossAxis(direction)
	local padAcross = halfExtentAlong(startPad, side) * 2
	local padAlong = halfExtentAlong(startPad, direction) * 2
	-- Centred, so the depth available behind the marker is half the pad.
	local sizeAcross, sizeAlong = StageLayout.SpawnMarkerSize(padAcross, padAlong, padAlong / 2)

	local position = startPad.Position * Vector3.new(1, 0, 1) + Vector3.new(0, topSurfaceY(startPad), 0)
	spawnPart.Size = Vector3.new(sizeAcross, 1, sizeAlong)
	-- Facing down the course is the load-bearing half of this: the grid is laid
	-- out in the marker's own space and builds rows BACKWARDS, so a marker
	-- pointing anywhere else spreads the field along the course instead of
	-- across it and hands the front row a head start.
	spawnPart.CFrame = CFrame.lookAt(position, position + direction)
	spawnPart.Anchored = true
	-- Measured, never stood on: it exists so buildStartGrid can read a size and
	-- a facing, and the pad underneath is what holds the field up. The authored
	-- markers were collidable islands, which is also why they dragged the fall
	-- floor around (getFallFloorY takes the lowest collidable part in the
	-- folder).
	spawnPart.Transparency = 1
	spawnPart.CanCollide = false
	spawnPart.CanTouch = false
	spawnPart.CanQuery = false
end

-- Stage1-4 carry a StartLine gate (touch it to queue -- see StageService) that
-- Stage5-8 have no equivalent of, so there is nothing to match it to. It is
-- re-seated rather than restyled or removed: the pad it stood at the back edge
-- of now reaches ~20 studs further back, and a queue trigger buried under the
-- middle of the start grid is a worse gate than one you walk in through.
local function normalizeStartLine(stageFolder: Instance, startPad: BasePart, direction: Vector3)
	local line = stageFolder:FindFirstChild("StartLine")
	if not (line and line:IsA("BasePart")) then
		return
	end
	local gate = line :: BasePart

	local side = acrossAxis(direction)
	local width = halfExtentAlong(startPad, side) * 2 * StageLayout.Endpoint.BannerWidthFactor
	local height = halfExtentAlong(gate, Vector3.yAxis) * 2
	local thickness = StageLayout.Endpoint.BannerThickness

	local backEdge = startPad.Position:Dot(direction) - halfExtentAlong(startPad, direction)
	local position = direction * (backEdge + thickness / 2)
		+ side * startPad.Position:Dot(side)
		+ Vector3.new(0, topSurfaceY(startPad) + height / 2, 0)

	gate.Size = Vector3.new(width, height, thickness)
	gate.CFrame = CFrame.lookAt(position, position + direction)
	gate.Anchored = true
	-- Colour and material are left exactly as authored: it is not a finish, and
	-- StageDecorationService deliberately leaves both banners out of its
	-- per-weather palette so functional markers stay recognisable.
	gate.CanCollide = false
	gate.CanTouch = true
end

local function findFinishBanner(stageFolder: Instance, stageId: string): BasePart?
	-- By tag first, since that is what win detection actually binds to -- a
	-- banner that is not tagged is not the finish line no matter what it is
	-- called.
	for _, part in CollectionService:GetTagged("FinishLine") do
		if part:IsA("BasePart") and part:GetAttribute("StageId") == stageId then
			return part
		end
	end
	local named = stageFolder:FindFirstChild("FinishLine", true)
	return if named and named:IsA("BasePart") then named else nil
end

-- Re-seats the banner across the near edge of the finish pad: landing anywhere
-- on the pad means having crossed its near edge, whereas the authored banners
-- were thin gates hanging in the air a few studs PAST the far edge, which a
-- racer who lands and stops never touches at all.
--
-- This does move the timing plane, and it is the one change here that does. On
-- these four stages it lands roughly 13 studs earlier -- about half a second of
-- sprint -- so times set from now on are marginally quicker than the ones
-- already in the per-stage OrderedDataStores (LeaderboardService). The trade is
-- deliberate: a finish you can arrive at and not have finished is worse than a
-- boards discontinuity.
local function normalizeFinish(banner: BasePart, finishPad: BasePart, direction: Vector3)
	local side = acrossAxis(direction)
	local endpoint = StageLayout.Endpoint

	local width = halfExtentAlong(finishPad, side) * 2 * endpoint.BannerWidthFactor
	local nearEdge = finishPad.Position:Dot(direction) - halfExtentAlong(finishPad, direction)
	local position = direction * (nearEdge + endpoint.BannerThickness / 2)
		+ side * finishPad.Position:Dot(side)
		+ Vector3.new(0, topSurfaceY(finishPad) + endpoint.BannerHeight / 2, 0)

	-- Local Z is the thin axis once the part looks down the course, so this is
	-- a wall standing across the run -- the orientation a racer crosses.
	banner.Size = Vector3.new(width, endpoint.BannerHeight, endpoint.BannerThickness)
	banner.CFrame = CFrame.lookAt(position, position + direction)
	banner.Anchored = true
	StageEndpointService.ApplyFinishStyle(banner)
end

local function normalizeStage(stage: Stages.StageInfo, stagesFolder: Instance)
	local stageFolder = stagesFolder:FindFirstChild(stage.Id)
	if not stageFolder then
		return
	end

	local startPad = stageFolder:FindFirstChild("Platform_Start")
	local finishPad = stageFolder:FindFirstChild("Platform_Finish")
	if not (startPad and startPad:IsA("BasePart") and finishPad and finishPad:IsA("BasePart")) then
		-- BotService walks the course by these exact names, so a stage missing
		-- either is already broken for bot races -- worth a warning either way.
		warn(("StageEndpointService: %s has no Platform_Start/Platform_Finish pair -- skipping"):format(stage.Id))
		return
	end

	local direction = courseDirection(startPad :: BasePart, finishPad :: BasePart)
	if not direction then
		warn(("StageEndpointService: %s start and finish pads are stacked -- skipping"):format(stage.Id))
		return
	end

	local endpoint = StageLayout.Endpoint
	-- Pads first: everything below is positioned off their new edges and decks.
	growPad(startPad :: BasePart, direction, endpoint.StartPadAlong, endpoint.StartPadAcross, 1)
	growPad(finishPad :: BasePart, direction, endpoint.FinishPadAlong, endpoint.FinishPadAcross, -1)

	normalizeSpawn(stageFolder, stage.Id, startPad :: BasePart, direction)
	normalizeStartLine(stageFolder, startPad :: BasePart, direction)

	local banner = findFinishBanner(stageFolder, stage.Id)
	if banner then
		normalizeFinish(banner, finishPad :: BasePart, direction)
	else
		warn(("StageEndpointService: %s has no FinishLine part -- skipping its banner"):format(stage.Id))
	end
end

function StageEndpointService.Init()
	local stagesFolder = Workspace:FindFirstChild("Stages")
	if not stagesFolder then
		return
	end

	for _, stage in Stages do
		-- Generated stages are built to this convention already (see
		-- StageBuilderService), so re-deriving it for them would be work that
		-- can only introduce a difference.
		if not stage.Generated then
			normalizeStage(stage, stagesFolder)
		end
	end
end

return StageEndpointService
