local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Stages = require(Shared.Stages)

-- Every course runs through the inside of a HOUSE ROOM.
--
-- This replaces the outdoor scenery fields entirely (forests, crystal fields,
-- rock moors). Those were built against an open horizon and every problem they
-- had came from that: stages seeing each other, floors at mismatched heights,
-- islands ending in open sky. A room has none of those problems by
-- construction -- four walls and a ceiling mean a stage cannot see anything but
-- itself, no matter what sits 60 studs away or 200 studs overhead.
--
-- THE SCALE IS DELIBERATE. A course is 220-470 studs long, so a room built
-- around one is enormous by Roblox standards, and the furniture is scaled to
-- match it rather than to the player. The result reads as a tiny character
-- crossing a normal room -- which is the look the reference is of, and a
-- well-worn Roblox genre in its own right. Furniture sized to the PLAYER in a
-- room this big would just look like litter on a plain.
--
-- THE FLOOR IS THE VOID SLAB. Rather than laying a decorative floor over the
-- fall trigger and hoping they agree, the slab is resized to the room and
-- restyled as floorboards -- so the thing you see underfoot and the thing that
-- catches a missed jump are the same part. Falling lands you on the floor of
-- the room and recovers you, exactly as it reads.
local StageRoomService = {}

local ROOM_FOLDER_NAME = "StageRooms"

-- Floor beyond the course on every side. Enough that the run never hugs a
-- skirting board, and that furniture has somewhere to stand.
local ROOM_MARGIN = 70

-- Ceiling height as a share of the room's SHORT side, so a narrow hall doesn't
-- come out as a lift shaft and a wide room doesn't come out as a crawlspace.
local CEILING_RATIO = 0.62
local CEILING_MIN, CEILING_MAX = 70, 150

local WALL_THICKNESS = 8
local SKIRTING_HEIGHT = 14
local WAINSCOT_RATIO = 0.34

type RoomTheme = {
	Name: string,
	FloorColor: Color3,
	FloorMaterial: Enum.Material,
	WallColor: Color3,
	WallMaterial: Enum.Material,
	WainscotColor: Color3,
	CeilingColor: Color3,
	Accent: Color3,
}

-- One room per stage, so the eight are told apart by the place they are rather
-- than by a recoloured platform. Keyed by stage id, not by weather: weather
-- still drives the light coming through the windows, but a kitchen is a
-- kitchen whether it is sunny or dark outside.
local ROOMS: { [string]: RoomTheme } = {
	Stage1 = {
		Name = "Living Room",
		FloorColor = Color3.fromRGB(181, 133, 86),
		FloorMaterial = Enum.Material.WoodPlanks,
		WallColor = Color3.fromRGB(233, 197, 142),
		WallMaterial = Enum.Material.Wood,
		WainscotColor = Color3.fromRGB(140, 96, 60),
		CeilingColor = Color3.fromRGB(246, 243, 236),
		Accent = Color3.fromRGB(86, 196, 214),
	},
	Stage2 = {
		Name = "Kitchen",
		FloorColor = Color3.fromRGB(226, 224, 214),
		FloorMaterial = Enum.Material.Marble,
		WallColor = Color3.fromRGB(176, 214, 196),
		WallMaterial = Enum.Material.SmoothPlastic,
		WainscotColor = Color3.fromRGB(120, 160, 146),
		CeilingColor = Color3.fromRGB(250, 250, 246),
		Accent = Color3.fromRGB(232, 148, 92),
	},
	Stage3 = {
		Name = "Bedroom",
		FloorColor = Color3.fromRGB(122, 88, 62),
		FloorMaterial = Enum.Material.WoodPlanks,
		WallColor = Color3.fromRGB(168, 152, 202),
		WallMaterial = Enum.Material.SmoothPlastic,
		WainscotColor = Color3.fromRGB(104, 92, 138),
		CeilingColor = Color3.fromRGB(236, 232, 244),
		Accent = Color3.fromRGB(120, 208, 224),
	},
	Stage4 = {
		Name = "Bathroom",
		FloorColor = Color3.fromRGB(232, 238, 242),
		FloorMaterial = Enum.Material.Marble,
		WallColor = Color3.fromRGB(178, 210, 228),
		WallMaterial = Enum.Material.SmoothPlastic,
		WainscotColor = Color3.fromRGB(226, 234, 240),
		CeilingColor = Color3.fromRGB(250, 252, 254),
		Accent = Color3.fromRGB(96, 190, 210),
	},
	Stage5 = {
		Name = "Attic",
		FloorColor = Color3.fromRGB(148, 112, 78),
		FloorMaterial = Enum.Material.Wood,
		WallColor = Color3.fromRGB(160, 138, 112),
		WallMaterial = Enum.Material.Wood,
		WainscotColor = Color3.fromRGB(112, 90, 68),
		CeilingColor = Color3.fromRGB(196, 182, 164),
		Accent = Color3.fromRGB(214, 178, 94),
	},
	Stage6 = {
		Name = "Study",
		FloorColor = Color3.fromRGB(102, 72, 50),
		FloorMaterial = Enum.Material.WoodPlanks,
		WallColor = Color3.fromRGB(92, 128, 106),
		WallMaterial = Enum.Material.SmoothPlastic,
		WainscotColor = Color3.fromRGB(74, 54, 40),
		CeilingColor = Color3.fromRGB(238, 234, 224),
		Accent = Color3.fromRGB(216, 170, 92),
	},
	Stage7 = {
		Name = "Workshop",
		FloorColor = Color3.fromRGB(150, 150, 154),
		FloorMaterial = Enum.Material.Concrete,
		WallColor = Color3.fromRGB(128, 132, 138),
		WallMaterial = Enum.Material.Concrete,
		WainscotColor = Color3.fromRGB(96, 100, 106),
		CeilingColor = Color3.fromRGB(206, 208, 212),
		Accent = Color3.fromRGB(228, 152, 64),
	},
	Stage8 = {
		Name = "Playroom",
		FloorColor = Color3.fromRGB(206, 164, 112),
		FloorMaterial = Enum.Material.WoodPlanks,
		WallColor = Color3.fromRGB(238, 206, 120),
		WallMaterial = Enum.Material.SmoothPlastic,
		WainscotColor = Color3.fromRGB(196, 158, 92),
		CeilingColor = Color3.fromRGB(250, 246, 232),
		Accent = Color3.fromRGB(228, 110, 128),
	},
}

type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

-- Everything this builds is decoration standing beside a timed course, so it
-- all carries the same contract the old scenery did: never collidable, never
-- touchable, never in a raycast. A collidable chair beside a landing zone
-- changes a jump; a touchable one can shadow a checkpoint's own Touched.
local function decor(parent: Instance, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): BasePart
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Parent = parent
	return part
end

-- The room SHELL -- walls and ceiling -- is real geometry, unlike the
-- furniture. It is the boundary of the stage: a racer flung sideways by a
-- bounce pad should stop at the wall rather than sail out over the map, and a
-- Blink raycast should stop there too. Still never touchable, so it can never
-- fire a Touched handler StageService is listening for.
--
-- The walls sit ROOM_MARGIN (70) studs beyond the void slab and the course runs
-- inside that slab, so nothing solid here is ever within reach of a jump.
local function structure(parent: Instance, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): BasePart
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Parent = parent
	return part
end

local function findVoid(stageFolder: Instance): BasePart?
	for _, part in stageFolder:GetChildren() do
		if part:IsA("BasePart") and part.Name == "VoidZone" then
			return part
		end
	end
	return nil
end

local function platformBounds(stageFolder: Instance): (Vector3?, Vector3?)
	local min, max
	for _, part in stageFolder:GetChildren() do
		if part:IsA("BasePart") and part.Name:match("^Platform") then
			local half = (part :: BasePart).Size / 2
			local low, high = (part :: BasePart).Position - half, (part :: BasePart).Position + half
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

-- WALLS, SKIRTING AND WAINSCOT ---------------------------------------------

local function buildShell(parent: Folder, room: Rect, floorY: number, height: number, theme: RoomTheme)
	local width, depth = room.maxX - room.minX, room.maxZ - room.minZ
	local midX, midZ = (room.minX + room.maxX) / 2, (room.minZ + room.maxZ) / 2
	local t = WALL_THICKNESS
	local wainscot = math.max(SKIRTING_HEIGHT * 2, height * WAINSCOT_RATIO)

	-- Each wall is drawn as three stacked bands -- dark panelling low, painted
	-- wall above, a thin skirting line between -- because a single flat slab
	-- reads as a backdrop while banding reads as a room. Same trick the
	-- reference uses.
	local sides = {
		{ cf = CFrame.new(midX, 0, room.minZ - t / 2), span = width + t * 2, axis = "Z" },
		{ cf = CFrame.new(midX, 0, room.maxZ + t / 2), span = width + t * 2, axis = "Z" },
		{ cf = CFrame.new(room.minX - t / 2, 0, midZ), span = depth, axis = "X" },
		{ cf = CFrame.new(room.maxX + t / 2, 0, midZ), span = depth, axis = "X" },
	}
	for _, side in sides do
		local function band(bottom: number, top: number, color: Color3, material: Enum.Material)
			local h = top - bottom
			local centre = Vector3.new(side.cf.X, floorY + bottom + h / 2, side.cf.Z)
			local size = if side.axis == "Z" then Vector3.new(side.span, h, t) else Vector3.new(t, h, side.span)
			structure(parent, size, CFrame.new(centre), color, material)
		end
		band(0, wainscot, theme.WainscotColor, theme.WallMaterial)
		band(wainscot, wainscot + 2.5, theme.Accent, Enum.Material.SmoothPlastic)
		band(wainscot + 2.5, height, theme.WallColor, theme.WallMaterial)
	end

	-- Ceiling, and a cornice line where it meets the wall.
	structure(
		parent,
		Vector3.new(width + t * 2, t, depth + t * 2),
		CFrame.new(midX, floorY + height + t / 2, midZ),
		theme.CeilingColor,
		Enum.Material.SmoothPlastic
	)
end

-- FURNITURE -----------------------------------------------------------------

-- A window: a recessed frame with a bright pane, plus a light so the room
-- actually brightens near it. Windows are what stop a big interior reading as a
-- box, and they carry the outdoor weather inside without opening a sightline.
local function buildWindow(parent: Folder, cf: CFrame, w: number, h: number)
	decor(parent, Vector3.new(w + 6, h + 6, 3), cf, Color3.fromRGB(250, 250, 248), Enum.Material.SmoothPlastic)
	local pane = decor(
		parent,
		Vector3.new(w, h, 1.6),
		cf * CFrame.new(0, 0, 0.9),
		Color3.fromRGB(226, 244, 255),
		Enum.Material.Neon
	)
	pane.Transparency = 0.25
	-- Glazing bars, so it reads as a window rather than a lit rectangle.
	decor(
		parent,
		Vector3.new(2, h, 2),
		cf * CFrame.new(0, 0, 1.2),
		Color3.fromRGB(250, 250, 248),
		Enum.Material.SmoothPlastic
	)
	decor(
		parent,
		Vector3.new(w, 2, 2),
		cf * CFrame.new(0, 0, 1.2),
		Color3.fromRGB(250, 250, 248),
		Enum.Material.SmoothPlastic
	)

	local light = Instance.new("PointLight")
	light.Brightness = 1.6
	light.Range = math.max(w, h) * 1.6
	light.Color = Color3.fromRGB(255, 248, 232)
	light.Parent = pane
end

-- A pendant lamp hanging from the ceiling, cord and all.
local function buildLamp(parent: Folder, x: number, z: number, ceilingY: number, drop: number)
	decor(
		parent,
		Vector3.new(1.6, drop, 1.6),
		CFrame.new(x, ceilingY - drop / 2, z),
		Color3.fromRGB(60, 56, 52),
		Enum.Material.Metal
	)
	local shade = decor(
		parent,
		Vector3.new(drop * 0.9, drop * 0.42, drop * 0.9),
		CFrame.new(x, ceilingY - drop, z),
		Color3.fromRGB(252, 246, 232),
		Enum.Material.Neon
	)
	local light = Instance.new("PointLight")
	light.Brightness = 2
	light.Range = drop * 6
	light.Color = Color3.fromRGB(255, 244, 214)
	light.Parent = shade
end

-- A counter run: carcass, worktop, and a darker plinth so it doesn't look like
-- a slab sitting on the floor.
local function buildCounter(
	parent: Folder,
	cf: CFrame,
	length: number,
	depthStuds: number,
	height: number,
	theme: RoomTheme
)
	decor(
		parent,
		Vector3.new(length, height, depthStuds),
		cf * CFrame.new(0, height / 2, 0),
		theme.WainscotColor,
		Enum.Material.Wood
	)
	decor(
		parent,
		Vector3.new(length + 4, height * 0.09, depthStuds + 4),
		cf * CFrame.new(0, height + height * 0.045, 0),
		Color3.fromRGB(238, 234, 226),
		Enum.Material.Marble
	)
	decor(
		parent,
		Vector3.new(length, height * 0.14, depthStuds + 1),
		cf * CFrame.new(0, height * 0.07, 0),
		Color3.fromRGB(52, 44, 38),
		Enum.Material.Wood
	)
end

-- A framed picture.
local function buildFrame(parent: Folder, cf: CFrame, size: number, accent: Color3)
	decor(parent, Vector3.new(size, size * 1.25, 2.5), cf, Color3.fromRGB(86, 62, 42), Enum.Material.Wood)
	decor(
		parent,
		Vector3.new(size * 0.78, size * 1.0, 1),
		cf * CFrame.new(0, 0, 1),
		accent,
		Enum.Material.SmoothPlastic
	)
end

-- A potted plant: pot, soil, and a few overlapping leaf spheres.
local function buildPlant(parent: Folder, x: number, y: number, z: number, scale: number)
	decor(
		parent,
		Vector3.new(10 * scale, 12 * scale, 10 * scale),
		CFrame.new(x, y + 6 * scale, z),
		Color3.fromRGB(186, 118, 84),
		Enum.Material.Slate
	)
	local rng = Random.new(math.floor(x * 3 + z * 7))
	for i = 1, 5 do
		local r = 7 * scale + rng:NextNumber() * 5 * scale
		local ball = decor(
			parent,
			Vector3.new(r, r, r),
			CFrame.new(
				x + (rng:NextNumber() - 0.5) * 12 * scale,
				y + 14 * scale + i * 3.2 * scale,
				z + (rng:NextNumber() - 0.5) * 12 * scale
			),
			Color3.fromRGB(76, 150 + math.floor(rng:NextNumber() * 40), 84),
			Enum.Material.Grass
		)
		ball.Shape = Enum.PartType.Ball
	end
end

-- A rug on the floor, purely to break up a large plane of boards.
local function buildRug(parent: Folder, x: number, z: number, floorY: number, w: number, d: number, accent: Color3)
	decor(parent, Vector3.new(w, 0.6, d), CFrame.new(x, floorY + 0.4, z), accent, Enum.Material.Fabric)
	decor(
		parent,
		Vector3.new(w * 0.82, 0.7, d * 0.82),
		CFrame.new(x, floorY + 0.5, z),
		Color3.fromRGB(246, 242, 234),
		Enum.Material.Fabric
	)
end

-- Places furniture along the walls, skipping anything that would land on the
-- run. The course keeps a clear corridor; the room fills in around it.
local function furnish(
	parent: Folder,
	room: Rect,
	floorY: number,
	height: number,
	courseMin: Vector3,
	courseMax: Vector3,
	theme: RoomTheme
)
	local width, depth = room.maxX - room.minX, room.maxZ - room.minZ
	local alongX = width >= depth
	local runLength = if alongX then width else depth

	local function clearOfCourse(x: number, z: number, pad: number): boolean
		return x < courseMin.X - pad or x > courseMax.X + pad or z < courseMin.Z - pad or z > courseMax.Z + pad
	end

	-- Windows and pictures ride the two long walls, alternating.
	local spacing = 150
	local count = math.max(2, math.floor(runLength / spacing))
	for i = 1, count do
		local t = (i - 0.5) / count
		for _, side in { -1, 1 } do
			local x, z, face
			if alongX then
				x = room.minX + width * t
				z = if side < 0 then room.minZ else room.maxZ
				face = CFrame.new(x, floorY + height * 0.58, z) * CFrame.Angles(0, if side < 0 then 0 else math.pi, 0)
			else
				z = room.minZ + depth * t
				x = if side < 0 then room.minX else room.maxX
				face = CFrame.new(x, floorY + height * 0.58, z)
					* CFrame.Angles(0, if side < 0 then math.pi / 2 else -math.pi / 2, 0)
			end
			if i % 2 == 1 then
				buildWindow(parent, face, math.min(90, runLength / count * 0.5), height * 0.34)
			else
				buildFrame(parent, face, 26, theme.Accent)
			end
		end
	end

	-- Pendant lamps down the middle of the ceiling, offset from the run so they
	-- light it without hanging in front of a jump.
	local lampCount = math.max(2, math.floor(runLength / 190))
	for i = 1, lampCount do
		local t = (i - 0.5) / lampCount
		local x = if alongX then room.minX + width * t else (room.minX + room.maxX) / 2
		local z = if alongX then (room.minZ + room.maxZ) / 2 else room.minZ + depth * t
		buildLamp(parent, x, z, floorY + height, math.max(18, height * 0.22))
	end

	-- Big pieces in the corners, where they can never crowd the course.
	local inset = 60
	local corners = {
		{ room.minX + inset, room.minZ + inset },
		{ room.maxX - inset, room.minZ + inset },
		{ room.minX + inset, room.maxZ - inset },
		{ room.maxX - inset, room.maxZ - inset },
	}
	for index, corner in corners do
		local x, z = corner[1], corner[2]
		if clearOfCourse(x, z, 40) then
			if index == 1 then
				buildCounter(parent, CFrame.new(x, floorY, z), math.min(180, width * 0.3), 46, 40, theme)
			elseif index == 2 then
				-- Was a wall-mounted screen. It read as a flat black box stuck to
				-- the wall rather than a television, so the corner takes a plant
				-- instead -- the one prop in the set that did read correctly.
				buildPlant(parent, x, floorY, z, 3.1)
			elseif index == 3 then
				buildPlant(parent, x, floorY, z, 2.6)
			else
				buildRug(parent, x, z, floorY, 120, 90, theme.Accent)
			end
		end
	end
end

function StageRoomService.Start()
	local stagesFolder = Workspace:FindFirstChild("Stages")
	if not stagesFolder then
		return
	end

	local existing = Workspace:FindFirstChild(ROOM_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = ROOM_FOLDER_NAME
	root.Parent = Workspace

	for _, stage in Stages do
		local theme = ROOMS[stage.Id]
		local stageFolder = stagesFolder:FindFirstChild(stage.Id)
		local void = stageFolder and findVoid(stageFolder)
		-- Plain statement, not an `if ... then ... else` expression: that form
		-- yields exactly ONE value, so platformBounds' second return was being
		-- discarded and courseMax always came back nil -- which silently failed
		-- the guard below and built no rooms at all.
		local courseMin, courseMax
		if stageFolder then
			courseMin, courseMax = platformBounds(stageFolder)
		end
		if theme and void and courseMin and courseMax then
			local room: Rect = {
				minX = void.Position.X - void.Size.X / 2 - ROOM_MARGIN,
				maxX = void.Position.X + void.Size.X / 2 + ROOM_MARGIN,
				minZ = void.Position.Z - void.Size.Z / 2 - ROOM_MARGIN,
				maxZ = void.Position.Z + void.Size.Z / 2 + ROOM_MARGIN,
			}

			-- The slab becomes the floorboards, grown to the room. One part is
			-- both the surface you see and the trigger that catches a fall, so
			-- the two can never disagree about where the floor is.
			local floorY = void.Position.Y + void.Size.Y / 2
			void.Size = Vector3.new(room.maxX - room.minX, void.Size.Y, room.maxZ - room.minZ)
			void.Position =
				Vector3.new((room.minX + room.maxX) / 2, floorY - void.Size.Y / 2, (room.minZ + room.maxZ) / 2)
			void.Color = theme.FloorColor
			void.Material = theme.FloorMaterial
			void.Transparency = 0

			local shortSide = math.min(room.maxX - room.minX, room.maxZ - room.minZ)
			local height = math.clamp(shortSide * CEILING_RATIO, CEILING_MIN, CEILING_MAX)

			local folder = Instance.new("Folder")
			folder.Name = stage.Id
			folder.Parent = root

			buildShell(folder, room, floorY, height, theme)
			furnish(folder, room, floorY, height, courseMin, courseMax, theme)
		end
	end
end

return StageRoomService
