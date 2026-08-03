local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Stages = require(Shared.Stages)

-- The environment each stage sits inside, so a course reads as a PLACE rather
-- than a row of platforms in empty space.
--
-- StageDecorationService gives each stage a per-weather palette; this fills the
-- world around it. A Sunny stage stands in a forest that closes in on every
-- side and continues past both ends of the run; a Night stage in a crystal
-- field; a Stormy one among rock spires.
--
-- HOW THE FIELD IS BUILT, and why it is not a grid.
--
-- The first version scattered one prop size on a jittered lattice, and it read
-- as exactly that: a lattice of identical trees. Three things separate a real
-- stand of trees from a scatter, and all three are implemented below.
--
--   * VARIABLE-RADII POISSON DISK. Every prop claims a radius proportional to
--     its own width, and no prop may be placed inside another's. This is the
--     standard vegetation-scattering approach: it produces the irregular-but-
--     even spacing of a real canopy, where purely random placement clumps into
--     blobs and a grid reads as rows. Big trees push their neighbours away;
--     undergrowth packs into the gaps between them.
--
--   * REVERSE-J SIZE DISTRIBUTION. Natural forests hold many juveniles and
--     progressively fewer large trees -- a negative exponential, and one of the
--     most consistent findings in forest structure. The weights in SIZE_CLASSES
--     follow that curve, so a field is mostly undergrowth and saplings with a
--     handful of giants standing over it. Uniform sizing is the single thing
--     that most makes scattered props look placed rather than grown.
--
--   * DENSITY FROM NOISE. Coverage is modulated by Perlin noise, so the field
--     has thickets and clearings rather than one flat density everywhere.
--
-- FOUR RULES ALSO GOVERN WHERE IT MAY BUILD. The first two are safety, the last
-- two stop a dense field wrecking the rest of the map:
--
--   1. NOTHING IT CREATES MAY TOUCH GAMEPLAY. Every prop is CanCollide = false,
--      CanQuery = false and CanTouch = false. A collidable prop beside a landing
--      zone changes a jump; a touchable one can shadow a checkpoint's own
--      Touched. Props never enter the course corridor.
--
--   2. IT LIVES OUTSIDE THE STAGES FOLDER. StageBuilderService places the
--      Stage5-8 sky courses from the bounds of every BasePart already under
--      Workspace.Stages (its existingBounds). Props parented into a stage folder
--      would enlarge those bounds and move the courses the leaderboards key to.
--
--   3. EACH POSITION BELONGS TO EXACTLY ONE STAGE. Stage1 and Stage4's slabs are
--      only 62 studs apart and overlap entirely in Z; a field deep enough to
--      surround either reaches the other, and Stage1 is Sunny while Stage4 is
--      Windy. Every position is awarded to the NEAREST ground stage, so fields
--      meet along a seam instead of interleaving trees with cloud banks.
--
--   4. THE LOBBY IS OFF LIMITS. Stage3's slab is 83 studs from the plaza rim.
local StageSceneryService = {}

local SCENERY_FOLDER_NAME = "StageScenery"

-- One entry in a theme's size mix. Weight is relative frequency; the list is
-- ordered small to large and the weights fall away, which is the reverse-J.
type SizeClass = {
	Prop: string,
	-- Multiplier on the theme's base height.
	Scale: number,
	Weight: number,
	-- Optional vertical elongation applied AFTER scaling, for the canopy layer.
	-- The generated TallTree mesh came out at a height:width ratio of only 1.7,
	-- nothing like the bare vertical trunks of a real wood, and a mesh cannot be
	-- re-proportioned after generation -- so the trunk classes stretch on Y
	-- only. Scenery seen from a distance, and it buys the vertical silhouette
	-- that makes a canopy feel overhead rather than beside you.
	Stretch: number?,
}

type Theme = {
	-- Base height in studs; every class scales off this.
	Height: number,
	Classes: { SizeClass },
	-- How far past the stage's own slab the field reaches.
	Depth: number,
	-- Sunk into the surface so props look grown rather than set down.
	Bury: number,
	-- Tighter packing = denser field. Multiplies each prop's claimed radius, so
	-- below 1 canopies are allowed to overlap.
	Packing: number,
	-- Colour and material for the flat ground sheet laid under the field.
	FloorColor: Color3,
	FloorMaterial: Enum.Material,
}

-- Sunny is the reference mix -- it is the one the reference photo was of, and
-- the others follow its shape: a broad base of small things, a middle of
-- ordinary ones, and a few large ones standing over the rest.
local THEMES: { [string]: Theme } = {
	Sunny = {
		Height = 16,
		Depth = 150,
		Bury = 1,
		Packing = 0.82,
		FloorColor = Color3.fromRGB(86, 68, 44),
		FloorMaterial = Enum.Material.Ground,
		Classes = {
			{ Prop = "Shrub", Scale = 0.34, Weight = 32 },
			{ Prop = "Tree", Scale = 0.42, Weight = 20 },
			{ Prop = "Tree", Scale = 0.80, Weight = 16 },
			{ Prop = "TallTree", Scale = 1.35, Weight = 15, Stretch = 1.5 },
			{ Prop = "TallTree", Scale = 1.90, Weight = 10, Stretch = 1.65 },
			{ Prop = "Tree", Scale = 2.40, Weight = 7 },
		},
	},
	Stormy = {
		Height = 15,
		Depth = 150,
		Bury = 2,
		Packing = 0.9,
		FloorColor = Color3.fromRGB(58, 62, 70),
		FloorMaterial = Enum.Material.Slate,
		Classes = {
			{ Prop = "Spire", Scale = 0.28, Weight = 34 },
			{ Prop = "Spire", Scale = 0.55, Weight = 24 },
			{ Prop = "Spire", Scale = 1.00, Weight = 20 },
			{ Prop = "Spire", Scale = 1.70, Weight = 14, Stretch = 1.3 },
			{ Prop = "Spire", Scale = 2.60, Weight = 8, Stretch = 1.45 },
		},
	},
	Night = {
		Height = 13,
		Depth = 150,
		Bury = 2,
		Packing = 0.88,
		FloorColor = Color3.fromRGB(30, 22, 46),
		FloorMaterial = Enum.Material.Slate,
		Classes = {
			{ Prop = "Crystal", Scale = 0.30, Weight = 33 },
			{ Prop = "Crystal", Scale = 0.60, Weight = 25 },
			{ Prop = "Crystal", Scale = 1.05, Weight = 19 },
			{ Prop = "Crystal", Scale = 1.80, Weight = 15, Stretch = 1.35 },
			{ Prop = "Crystal", Scale = 2.70, Weight = 8, Stretch = 1.5 },
		},
	},
	-- Windy is a GROUND course, and that is why it uses rock rather than the
	-- cloud prop its pale ice palette might suggest. Cloud banks resting on a
	-- surface read as snowmen, not weather -- clouds only work for Cloudy,
	-- which floats. This is a wind-scoured moor instead: bare rock breaking
	-- through pale ground, which suits an exposed course far better.
	Windy = {
		Height = 11,
		Depth = 150,
		Bury = 2.5,
		Packing = 0.92,
		FloorColor = Color3.fromRGB(216, 228, 238),
		FloorMaterial = Enum.Material.Sand,
		Classes = {
			{ Prop = "Spire", Scale = 0.30, Weight = 36 },
			{ Prop = "Spire", Scale = 0.58, Weight = 25 },
			{ Prop = "Spire", Scale = 1.00, Weight = 19 },
			{ Prop = "Spire", Scale = 1.60, Weight = 13, Stretch = 1.25 },
			{ Prop = "Spire", Scale = 2.30, Weight = 7, Stretch = 1.4 },
		},
	},
	Cloudy = {
		Height = 10,
		Depth = 150,
		Bury = 0,
		Packing = 0.95,
		FloorColor = Color3.fromRGB(206, 212, 222),
		FloorMaterial = Enum.Material.Sand,
		Classes = {
			{ Prop = "Cloud", Scale = 0.45, Weight = 30 },
			{ Prop = "Cloud", Scale = 0.80, Weight = 26 },
			{ Prop = "Cloud", Scale = 1.30, Weight = 22 },
			{ Prop = "Cloud", Scale = 2.10, Weight = 14 },
			{ Prop = "Cloud", Scale = 3.20, Weight = 8 },
		},
	},
}

-- Gap between the course's platform envelope and the nearest prop edge. Sized
-- off a jump rather than by eye: StageLayout allows gaps up to ~12 studs, so a
-- racer can legitimately be several studs off the deck mid-jump and must never
-- find scenery filling that space.
local COURSE_CLEARANCE = 6

-- A slab within this of the baseplate is a GROUND course (Stage1-4 sit ~2 studs
-- above it); the rest float 150-450 studs up with nothing underneath.
local GROUND_SNAP = 20

-- Clear space kept around the lobby plaza. The rim is radius 93 and the lobby's
-- own tree ring sits at ~102, so this clears both with room to spare.
local LOBBY_KEEPOUT = 135

-- Wavelength of the density noise, in studs. Around 90 gives thickets and
-- clearings a player runs past over a few seconds, rather than a texture.
local DENSITY_SCALE = 0.011
-- Floor on the noise, so a clearing thins out rather than becoming bare ground.
local DENSITY_FLOOR = 0.35

type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

local function slabRect(void: BasePart): Rect
	return {
		minX = void.Position.X - void.Size.X / 2,
		maxX = void.Position.X + void.Size.X / 2,
		minZ = void.Position.Z - void.Size.Z / 2,
		maxZ = void.Position.Z + void.Size.Z / 2,
	}
end

local function distanceToRect(x: number, z: number, rect: Rect): number
	local dx = math.max(rect.minX - x, 0, x - rect.maxX)
	local dz = math.max(rect.minZ - z, 0, z - rect.maxZ)
	return math.sqrt(dx * dx + dz * dz)
end

local function isPlatform(part: Instance): boolean
	return part:IsA("BasePart") and part.Name:match("^Platform") ~= nil
end

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

-- Weighted pick across a theme's size classes. The weights are the reverse-J,
-- so this returns undergrowth most of the time and a giant occasionally.
local function pickClass(rng: Random, theme: Theme): SizeClass
	local total = 0
	for _, class in theme.Classes do
		total += class.Weight
	end
	local roll = rng:NextNumber() * total
	local running = 0
	for _, class in theme.Classes do
		running += class.Weight
		if roll <= running then
			return class
		end
	end
	return theme.Classes[#theme.Classes]
end

-- Spatial hash over placed props, so the Poisson rejection test costs a handful
-- of neighbour lookups instead of a scan over everything already placed. With
-- several hundred props per stage the difference is the whole runtime.
type Hash = { cell: number, buckets: { [string]: { { x: number, z: number, r: number } } } }

local function newHash(cell: number): Hash
	return { cell = cell, buckets = {} }
end

local function hashKey(hash: Hash, x: number, z: number): string
	return ("%d,%d"):format(math.floor(x / hash.cell), math.floor(z / hash.cell))
end

local function hashFits(hash: Hash, x: number, z: number, r: number): boolean
	local cx, cz = math.floor(x / hash.cell), math.floor(z / hash.cell)
	for ox = -1, 1 do
		for oz = -1, 1 do
			local bucket = hash.buckets[("%d,%d"):format(cx + ox, cz + oz)]
			if bucket then
				for _, other in bucket do
					local dx, dz = other.x - x, other.z - z
					local minimum = other.r + r
					if dx * dx + dz * dz < minimum * minimum then
						return false
					end
				end
			end
		end
	end
	return true
end

local function hashAdd(hash: Hash, x: number, z: number, r: number)
	local key = hashKey(hash, x, z)
	local bucket = hash.buckets[key]
	if not bucket then
		bucket = {}
		hash.buckets[key] = bucket
	end
	table.insert(bucket, { x = x, z = z, r = r })
end

-- Spread WITHIN a class, on top of the spread between classes.
--
-- Six discrete classes produce six discrete sizes, and it showed: a height
-- histogram of the first build had 608 props in the 0-8 band, 89 in 8-16, then
-- literally zero across 16-32, then another spike at 32-40. Six spikes with
-- gaps between them, which is a size chart, not a forest. Jittering each
-- instance around its class turns the spikes into a continuum, and it is the
-- cheapest realism in the whole file.
local CLASS_JITTER = 0.34

-- Floor on the radius a prop may claim, regardless of how small it is.
--
-- Without it the smallest classes pack to their own scale: a 4-stud crystal
-- claims ~1.5 studs and Stage3 came back with 1,497 props, most of them ground
-- clutter too small to read individually. The floor costs nothing visually --
-- ground cover still reads as ground cover at this spacing -- and it is what
-- keeps the part count survivable on a phone.
local MIN_RADIUS = 3.5

-- Three numbers per prop, and they are deliberately not the same one:
--
--   size      what it is built at.
--   radius    what it claims against its NEIGHBOURS, scaled by Packing so
--             canopies may overlap and the field can close up.
--   halfWidth its true horizontal extent, used against the COURSE. Packing
--             must not apply here: it is a permission to overlap other props,
--             not permission to lean over the run. Measured with the packed
--             radius, a Sunny giant came within 3.8 studs of the deck while
--             COURSE_CLEARANCE claimed 6 -- the constant has to mean the gap a
--             player actually sees.
local function classFootprint(
	theme: Theme,
	class: SizeClass,
	template: BasePart,
	rng: Random
): (number, number, Vector3)
	local spread = 1 + (rng:NextNumber() - 0.5) * 2 * CLASS_JITTER
	local height = theme.Height * class.Scale * spread
	local scale = height / template.Size.Y
	local size = template.Size * scale
	if class.Stretch then
		size = Vector3.new(size.X, size.Y * class.Stretch, size.Z)
	end
	local halfWidth = math.max(size.X, size.Z) / 2
	local radius = math.max(MIN_RADIUS, halfWidth * theme.Packing)
	return radius, halfWidth, size
end

local function plant(template: BasePart, parent: Folder, position: Vector3, size: Vector3, rng: Random)
	local prop = template:Clone()
	prop.Size = size
	prop.CFrame = CFrame.new(position) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
	-- Re-asserted on the clone rather than trusted from the template: these four
	-- are the entire safety contract between decoration and gameplay.
	prop.Anchored = true
	prop.CanCollide = false
	prop.CanQuery = false
	prop.CanTouch = false
	prop.CastShadow = false
	prop.Parent = parent
end

-- Edge of a ground-cover tile. Coarse on purpose: fine enough that the seam
-- between two stages' floors is hidden under their fields, cheap enough that
-- covering four stages costs a couple of hundred parts.
local FLOOR_TILE = 60

-- The ground under a field, so it reads as forest floor rather than the
-- baseplate's bright lawn showing through a wood.
--
-- TILED, not one big rectangle, and that is the whole point. The first version
-- laid a single part spanning the full field region and obeyed none of the
-- rules the props obey -- so all four sheets reached the lobby (Stage3's
-- covered the spawn point outright) and overlapped each other by up to
-- 245x335 studs at an identical Y, which z-fights. Running the same lobby
-- keep-out and nearest-stage test per tile makes the floor follow exactly the
-- same boundary its own props do, so it cannot cover the plaza and two stages'
-- floors cannot occupy the same ground.
--
-- Visual only: never collidable, so players still stand on the baseplate
-- exactly as before.
local function layFloor(theme: Theme, folder: Folder, region: Rect, y: number, own: Rect, groundSlabs: { Rect }): number
	local tiles = 0
	-- Snapped to a GLOBAL lattice, not to each region's own corner.
	--
	-- Tiling from region.minX gave every stage its own grid origin, so two
	-- stages' tiles could half-overlap even when the nearest-stage test had
	-- correctly awarded their centres to different owners -- 17 overlapping
	-- pairs, measured. Aligning every stage to the same world-space lattice
	-- means both stages generate the IDENTICAL cell in a contested area, and
	-- the test then awards that one cell to exactly one of them. Tiles can
	-- abut; they can no longer intersect.
	local x = math.floor(region.minX / FLOOR_TILE) * FLOOR_TILE
	while x < region.maxX do
		local x2 = x + FLOOR_TILE
		local z = math.floor(region.minZ / FLOOR_TILE) * FLOOR_TILE
		while z < region.maxZ do
			local z2 = z + FLOOR_TILE
			local tile = { minX = x, maxX = x2, minZ = z, maxZ = z2 }
			local midX, midZ = (x + x2) / 2, (z + z2) / 2

			-- Lobby test uses the tile's NEAREST point, not its centre: a
			-- centre-only test would let a 60-stud tile poke 30 studs into the
			-- plaza, and the lobby's own tree ring sits at r=102.
			local ok = distanceToRect(0, 0, tile) >= LOBBY_KEEPOUT
			if ok then
				local ownDistance = distanceToRect(midX, midZ, own)
				for _, rect in groundSlabs do
					if distanceToRect(midX, midZ, rect) < ownDistance - 0.01 then
						ok = false
						break
					end
				end
			end

			if ok then
				local floor = Instance.new("Part")
				floor.Name = "GroundCover"
				floor.Anchored = true
				floor.CanCollide = false
				floor.CanQuery = false
				floor.CanTouch = false
				floor.CastShadow = false
				floor.TopSurface = Enum.SurfaceType.Smooth
				floor.BottomSurface = Enum.SurfaceType.Smooth
				floor.Color = theme.FloorColor
				floor.Material = theme.FloorMaterial
				floor.Size = Vector3.new(x2 - x, 0.4, z2 - z)
				floor.Position = Vector3.new(midX, y + 0.1, midZ)
				floor.Parent = folder
				tiles += 1
			end
			z += FLOOR_TILE
		end
		x += FLOOR_TILE
	end
	return tiles
end

local function fillGround(
	theme: Theme,
	props: Folder,
	folder: Folder,
	own: Rect,
	groundSlabs: { Rect },
	surfaceY: number
): number
	local region = {
		minX = own.minX - theme.Depth,
		maxX = own.maxX + theme.Depth,
		minZ = own.minZ - theme.Depth,
		maxZ = own.maxZ + theme.Depth,
	}
	layFloor(theme, folder, region, surfaceY, own, groundSlabs)

	local width, depth = region.maxX - region.minX, region.maxZ - region.minZ
	-- Dart throwing: attempts scale with area, and the Poisson test decides how
	-- many actually land. Overshooting attempts costs a little CPU at startup
	-- and buys a denser, more even field.
	local attempts = math.min(9000, math.floor(width * depth / 30))
	local hash = newHash(28)
	local placed = 0
	local rng = Random.new(math.floor(own.minX * 13 + own.minZ * 7))

	for _ = 1, attempts do
		local x = region.minX + rng:NextNumber() * width
		local z = region.minZ + rng:NextNumber() * depth

		if math.sqrt(x * x + z * z) >= LOBBY_KEEPOUT then
			local class = pickClass(rng, theme)
			local template = props:FindFirstChild(class.Prop) :: BasePart?
			if template then
				local radius, halfWidth, size = classFootprint(theme, class, template, rng)

				-- Off every slab, and nearer this stage than any other.
				local ownDistance = distanceToRect(x, z, own)
				local allowed = true
				for _, rect in groundSlabs do
					local d = distanceToRect(x, z, rect)
					if d < halfWidth + 3 or d < ownDistance - 0.01 then
						allowed = false
						break
					end
				end

				-- Thickets and clearings. math.noise returns roughly -0.5..0.5.
				if allowed then
					local density =
						math.clamp(0.5 + math.noise(x * DENSITY_SCALE, z * DENSITY_SCALE, 0.5) * 1.6, DENSITY_FLOOR, 1)
					if rng:NextNumber() > density then
						allowed = false
					end
				end

				if allowed and hashFits(hash, x, z, radius) then
					hashAdd(hash, x, z, radius)
					plant(template, folder, Vector3.new(x, surfaceY + size.Y / 2 - theme.Bury, z), size, rng)
					placed += 1
				end
			end
		end
	end
	return placed
end

-- A sky stage has no world to fill, only the slab it floats on -- ~110 studs
-- across against a ~30-stud run. Same sampler, bounded to the slab and kept off
-- the course.
local function fillSky(
	theme: Theme,
	props: Folder,
	folder: Folder,
	own: Rect,
	courseMin: Vector3,
	courseMax: Vector3,
	surfaceY: number
): number
	local width, depth = own.maxX - own.minX, own.maxZ - own.minZ
	local attempts = math.min(4000, math.floor(width * depth / 26))
	local hash = newHash(24)
	local placed = 0
	local rng = Random.new(math.floor(own.minX * 17 + own.minZ * 11))

	for _ = 1, attempts do
		local x = own.minX + rng:NextNumber() * width
		local z = own.minZ + rng:NextNumber() * depth
		local class = pickClass(rng, theme)
		local template = props:FindFirstChild(class.Prop) :: BasePart?
		if template then
			local radius, halfWidth, size = classFootprint(theme, class, template, rng)
			local clearX = x < courseMin.X - COURSE_CLEARANCE - halfWidth
				or x > courseMax.X + COURSE_CLEARANCE + halfWidth
			local clearZ = z < courseMin.Z - COURSE_CLEARANCE - halfWidth
				or z > courseMax.Z + COURSE_CLEARANCE + halfWidth
			local onSlab = x - radius > own.minX
				and x + radius < own.maxX
				and z - radius > own.minZ
				and z + radius < own.maxZ
			if (clearX or clearZ) and onSlab and hashFits(hash, x, z, radius) then
				hashAdd(hash, x, z, radius)
				plant(template, folder, Vector3.new(x, surfaceY + size.Y / 2 - theme.Bury, z), size, rng)
				placed += 1
			end
		end
	end
	return placed
end

local function decorate(
	stage: Stages.StageInfo,
	stageFolder: Instance,
	root: Folder,
	props: Folder,
	groundSlabs: { Rect }
)
	local theme = THEMES[stage.Weather]
	if not theme then
		return
	end
	local min, max = platformBounds(stageFolder)
	local void = findVoid(stageFolder)
	if not min or not max or not void then
		return
	end

	local slabTop = void.Position.Y + void.Size.Y / 2
	local baseplate = Workspace:FindFirstChild("Baseplate") :: BasePart?
	local groundTop = if baseplate then baseplate.Position.Y + baseplate.Size.Y / 2 else 0
	local onGround = (slabTop - groundTop) <= GROUND_SNAP

	local folder = Instance.new("Folder")
	folder.Name = stage.Id
	folder.Parent = root

	local own = slabRect(void)
	if onGround then
		fillGround(theme, props, folder, own, groundSlabs, groundTop)
	else
		fillSky(theme, props, folder, own, min, max, slabTop)
	end
end

-- Start, not Init, and deliberately so.
--
-- StageEndpointService reshapes the start/finish pads and then EXTENDS the void
-- slab out underneath them during the Init pass, and the slab footprint is what
-- every field here is built around. Running in Init would race it and measure a
-- slab about to grow. Loader calls every Init before any Start, so this is the
-- first moment the stages are finished being built, themed and resized.
-- (StageBuilderService's own build is earlier still -- require time.)
function StageSceneryService.Start()
	local props = ServerStorage:FindFirstChild("StageProps")
	if not props then
		-- The templates live in the .rbxl (MeshPart.MeshId cannot be assigned
		-- from a script at runtime, so a prop can only be cloned from one that
		-- already exists). Without them there is no scenery; every stage still
		-- builds, themes and plays exactly as before.
		return
	end

	local stagesFolder = Workspace:FindFirstChild("Stages")
	if not stagesFolder then
		return
	end

	local existing = Workspace:FindFirstChild(SCENERY_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = SCENERY_FOLDER_NAME
	root.Parent = Workspace

	-- Only the GROUND slabs, and that exclusion is load-bearing: distanceToRect
	-- is horizontal, and the sky courses' footprints are enormous (Stage5's
	-- spans X -327..17, straight over Stage1's forest). Counting them would
	-- punch holes in the ground fields wherever a course floats 150 studs
	-- overhead, which is nothing at all to a tree standing underneath it.
	local groundSlabs: { Rect } = {}
	local baseplate = Workspace:FindFirstChild("Baseplate") :: BasePart?
	local groundTop = if baseplate then baseplate.Position.Y + baseplate.Size.Y / 2 else 0
	for _, stage in Stages do
		local stageFolder = stagesFolder:FindFirstChild(stage.Id)
		local void = stageFolder and findVoid(stageFolder)
		if void and (void.Position.Y + void.Size.Y / 2 - groundTop) <= GROUND_SNAP then
			table.insert(groundSlabs, slabRect(void))
		end
	end

	for _, stage in Stages do
		local stageFolder = stagesFolder:FindFirstChild(stage.Id)
		if stageFolder then
			decorate(stage, stageFolder, root, props, groundSlabs)
		end
	end
end

return StageSceneryService
