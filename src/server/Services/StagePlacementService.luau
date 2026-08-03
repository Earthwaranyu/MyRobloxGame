local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Stages = require(Shared.Stages)

-- Requiring the builder is what guarantees the generated Stage5-8 courses EXIST
-- before anything below tries to move them. StageBuilderService does its work
-- at require time, so this require is the ordering, not the API.
require(script.Parent.StageBuilderService)

-- Lays all eight stages out as a 3x3 grid with the lobby in the middle:
--
--     Stage1   Stage2   Stage3
--     Stage4   [LOBBY]  Stage5
--     Stage6   Stage7   Stage8
--
-- Everything sits on one plane at ground level. Nothing floats.
--
-- WHY THIS EXISTS AT ALL. The eight courses grew up in two different places:
-- Stage1-4 were drawn by hand wherever looked right in Studio (at four
-- different altitudes, 62 studs apart in places), and Stage5-8 were generated
-- into the SKY, stacked 150-450 studs up, because the old 1000-stud baseplate
-- had no room beside the hand-built cluster. Every environment problem since
-- has traced back to that: stages visible from each other and from the lobby,
-- scenery floors at mismatched heights, rooms that overlapped by 341x431 studs
-- because their courses were closer together than a room is wide.
--
-- Placing them on a grid removes the cause rather than managing the symptom. A
-- room per cell then fits with space to spare, and no stage can see another
-- because there is a wall and half a grid pitch between them.
--
-- WHAT IT MOVES, AND WHY THAT IS SAFE. Each course is translated as one rigid
-- piece -- platforms, checkpoints, spawn, finish, void slab, gimmick parts, all
-- of it. A course's difficulty lives entirely in the distances BETWEEN its
-- parts, and a shared offset preserves every one of them exactly. Nothing about
-- any run changes except where in the world it happens.
local StagePlacementService = {}

-- Grid pitch, bounded by the baseplate.
--
-- A Roblox part cannot exceed 2048 studs on an axis, so the floor everything
-- stands on caps there and the grid has to fit inside it. The widest room is
-- Stage6's at 612 studs (a 472-stud course plus StageRoomService's margin), so
-- an X pitch of 676 puts the outermost room edge at 1002 -- just inside the
-- 1024 half-width (measured: 700 overhung the plate by 18 studs) -- and still leaves ~90 studs of daylight between
-- neighbouring rooms. Z is roomier: the deepest room is 400, so 620 leaves a
-- 120-stud gap and lands well inside the 1900-deep plate.
local CELL_X = 676
local CELL_Z = 620

-- Top surface of every stage's void slab, matching where the hand-built
-- courses already had theirs, and the height the lobby plaza sits at.
local SLAB_TOP = 2.5

-- Studs from the slab to the underside of the lowest platform. 3.5 is Stage1's
-- own figure -- the one course whose scale read correctly before any of this.
local STANDARD_RISE = 3.5

-- Column/row of each stage in the grid, as drawn. Column -1 is left, row -1 is
-- the top of the sketch; the lobby holds (0, 0) and no stage may use it.
local SLOTS: { [string]: { number } } = {
	Stage1 = { -1, -1 },
	Stage2 = { 0, -1 },
	Stage3 = { 1, -1 },
	Stage4 = { -1, 0 },
	Stage5 = { 1, 0 },
	Stage6 = { -1, 1 },
	Stage7 = { 0, 1 },
	Stage8 = { 1, 1 },
}

local function findVoid(stageFolder: Instance): BasePart?
	for _, part in stageFolder:GetDescendants() do
		if part:IsA("BasePart") and part.Name == "VoidZone" then
			return part
		end
	end
	return nil
end

-- Lowest surface a racer can actually stand on. Deliberately the same test
-- MatchService.getFallFloorY uses (collidable, and not the slab), so the height
-- this service sets and the height the fall watchdog measures agree.
local function lowestStandable(stageFolder: Instance, void: BasePart): number?
	local lowest = math.huge
	for _, part in stageFolder:GetDescendants() do
		if part:IsA("BasePart") and part ~= void and part.CanCollide then
			lowest = math.min(lowest, part.Position.Y - part.Size.Y / 2)
		end
	end
	return if lowest == math.huge then nil else lowest
end

local function translate(stageFolder: Instance, offset: Vector3, skip: BasePart?)
	for _, part in stageFolder:GetDescendants() do
		if part:IsA("BasePart") and part ~= skip then
			part.CFrame = part.CFrame + offset
		end
	end
end

-- The green wall across the start of Stage1-4.
--
-- It was a touch-to-queue gate: walk into it in the lobby era and you joined a
-- race (StageService binds onStartTouched to the "StartLine" tag). Now that
-- every stage is a sealed room a player is teleported into, nobody can reach
-- one on foot, so the gate is unreachable functionality -- and it renders as a
-- head-height green slab straight across the first jump.
--
-- Removed at REQUIRE time, before StageService's Init runs bindAll("StartLine"),
-- so no handler is ever bound to a part that is about to disappear.
local function removeStartGate(stageFolder: Instance)
	for _, part in stageFolder:GetDescendants() do
		if part:IsA("BasePart") and part.Name == "StartLine" then
			part:Destroy()
		end
	end
end

local function place(stageFolder: Instance, column: number, row: number)
	local void = findVoid(stageFolder)
	if not void then
		return
	end

	-- 1. Slide the whole course sideways so its slab centres on the grid cell.
	local target = Vector3.new(column * CELL_X, 0, row * CELL_Z)
	translate(stageFolder, Vector3.new(target.X - void.Position.X, 0, target.Z - void.Position.Z))

	-- 2. Drop the slab to ground level. Done on its own so the course above it
	--    can then be set relative to the slab rather than to wherever it was.
	local slabOffset = SLAB_TOP - (void.Position.Y + void.Size.Y / 2)
	void.CFrame = void.CFrame + Vector3.new(0, slabOffset, 0)

	-- 3. Set the run at a standard height above the slab. The sky courses sat
	--    35 studs up and the hand-built ones between 3.5 and 32 -- which is why
	--    a stage could look like a canopy seen from above rather than a course
	--    inside a place. Everything but the slab moves together.
	local lowest = lowestStandable(stageFolder, void)
	if lowest then
		translate(stageFolder, Vector3.new(0, SLAB_TOP + STANDARD_RISE - lowest, 0), void)
	end
end

-- Runs at REQUIRE time, not in Init(), and that ordering is load-bearing.
--
-- StageGimmickService reads every stage's platforms exactly once in its Init and
-- places bounce pads and moving-platform tracks against the positions it finds;
-- StageEndpointService reshapes the start/finish pads in its Init the same way.
-- Courses that moved after either had run would leave their gimmicks and
-- endpoints behind at the old coordinates. Loader requires every module before
-- calling any Init, so doing this at require time means the geometry is final
-- before a single Init sees it.
local function placeAll()
	local stagesFolder = Workspace:FindFirstChild("Stages")
	if not stagesFolder then
		return
	end
	for _, stage in Stages do
		local slot = SLOTS[stage.Id]
		local stageFolder = stagesFolder:FindFirstChild(stage.Id)
		if slot and stageFolder then
			removeStartGate(stageFolder)
			place(stageFolder, slot[1], slot[2])
		end
	end
end

placeAll()

function StagePlacementService.Init() end

return StagePlacementService
