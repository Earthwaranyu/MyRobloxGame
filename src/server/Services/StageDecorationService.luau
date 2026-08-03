local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Stages = require(Shared.Stages)

-- Every stage's platforms were the same uniform green SmoothPlastic
-- regardless of that stage's assigned weather (Sunny/Stormy/Night/Windy) --
-- WeatherService only ever recolors LIGHTING, and only for whichever stage
-- currently hosts the active race, it never touches the platform geometry
-- itself, so all 4 stages looked visually identical under different-colored
-- skies. This applies a one-time, static per-stage palette to every
-- platform + the surrounding void, unconditionally at server start (not
-- tied to whichever stage currently has the spotlight) since the platforms
-- themselves don't change between races.
local StageDecorationService = {}

type Palette = {
	PlatformColor: Color3,
	PlatformMaterial: Enum.Material,
}

local PALETTES: { [string]: Palette } = {
	Sunny = {
		PlatformColor = Color3.fromRGB(86, 205, 226),
		PlatformMaterial = Enum.Material.SmoothPlastic,
	},
	Stormy = {
		PlatformColor = Color3.fromRGB(86, 205, 226),
		PlatformMaterial = Enum.Material.SmoothPlastic,
	},
	Night = {
		PlatformColor = Color3.fromRGB(86, 205, 226),
		PlatformMaterial = Enum.Material.SmoothPlastic,
	},
	Windy = {
		PlatformColor = Color3.fromRGB(86, 205, 226),
		PlatformMaterial = Enum.Material.SmoothPlastic,
	},
	Cloudy = {
		PlatformColor = Color3.fromRGB(86, 205, 226),
		PlatformMaterial = Enum.Material.SmoothPlastic,
	},
}

-- StartLine/FinishLine (colored wall banners) and Checkpoint_* (neon
-- markers) are functional affordances players already read at a glance --
-- never re-themed per stage, so a palette change can't make them harder to
-- spot. Checkpoints DO get their own separate, stage-independent treatment
-- though (see decorateCheckpoint below) -- that's about telling them apart
-- from Stage4's speed strips, not about matching the stage's palette.
-- SpawnLocation is similarly left alone (not a BasePart match anyway, but
-- explicit here since it's the same "leave functional markers alone" idea).
local function isGenericPlatform(part: BasePart): boolean
	-- The void slab is deliberately NOT matched here: StageRoomService owns
	-- it now, restyling it as the room's floorboards and resizing it to the
	-- room. Two writers on one part is how a floor ends up disagreeing with
	-- itself about what it looks like.
	return part.Name:match("^Platform") ~= nil
end

local function decorateStage(stageFolder: Folder, palette: Palette)
	for _, part in stageFolder:GetChildren() do
		if part:IsA("BasePart") and isGenericPlatform(part) then
			part.Color = palette.PlatformColor
			part.Material = palette.PlatformMaterial
		end
	end
end

-- Checkpoints and Stage4's speed strips were, in practice, the same object:
-- both a flat square Neon pad lying on a platform, both light cyan --
-- RGB(80, 220, 255) vs RGB(120, 230, 255) -- at the same thickness and
-- roughly the same size. Nothing distinguished them at a glance, let alone at
-- running speed.
--
-- The fix follows the standard obby/racing split rather than just nudging the
-- hues apart, because colour alone is the weakest possible signal (it's also
-- the one that disappears for colourblind players):
--
--   Checkpoint -- a PLACE. Vertical, green, and completely static: a beacon
--                 column you can see over the platforms from a distance and
--                 navigate toward, sitting on the pad you touch.
--   Speed strip -- a VERB. Flat, orange, and animated: scrolling chevrons
--                 pointing down the track (the Mario Kart dash-panel
--                 convention). See StageGimmickService.
--
-- Different axis, different colour, different motion. They stay
-- distinguishable in greyscale (upright vs flat), for any form of colour
-- blindness (moving vs still), and from far enough away to plan a route.
local CHECKPOINT_COLOR = Color3.fromRGB(70, 235, 130)
local BEACON_HEIGHT = 16
local BEACON_THICKNESS = 0.55

local function addBeaconPart(checkpoint: BasePart, name: string, size: Vector3, offset: CFrame): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	-- Must never be touchable: StageService binds fall-recovery to the
	-- checkpoint part itself, and a stray collidable child could block a
	-- landing or shadow the pad's own Touched.
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = CHECKPOINT_COLOR
	part.Size = size
	part.CFrame = checkpoint.CFrame * offset
	part.Parent = checkpoint
	return part
end

local function decorateCheckpoint(checkpoint: BasePart)
	if checkpoint:GetAttribute("BeaconApplied") then
		return
	end
	checkpoint:SetAttribute("BeaconApplied", true)

	-- Green rather than the old cyan: "safe / progress saved" reads instantly,
	-- and it sits on the opposite side of the colour wheel from the strips'
	-- orange, which is the pairing that survives every common form of colour
	-- blindness.
	checkpoint.Color = CHECKPOINT_COLOR

	local halfHeight = checkpoint.Size.Y / 2

	local beacon = addBeaconPart(
		checkpoint,
		"CheckpointBeacon",
		Vector3.new(BEACON_THICKNESS, BEACON_HEIGHT, BEACON_THICKNESS),
		CFrame.new(0, halfHeight + BEACON_HEIGHT / 2, 0)
	)
	-- Translucent so a column this tall marks the spot without walling off the
	-- view of the platforms behind it.
	beacon.Transparency = 0.55

	-- Small banner near the top of the pole. The pole alone reads as a generic
	-- glow; the flag is what makes it unmistakably a checkpoint at distance.
	local flag = addBeaconPart(
		checkpoint,
		"CheckpointFlag",
		Vector3.new(2.6, 1.5, 0.18),
		CFrame.new(1.3 + BEACON_THICKNESS / 2, halfHeight + BEACON_HEIGHT - 1.6, 0)
	)
	flag.Transparency = 0.1
end

-- Defensive: confirmed live (twice) that re-syncing Baseplate's Rojo-managed
-- properties (default.project.json) can leave its Position at (0, 0, 0)
-- instead of the declared (0, -10, 0), even though the file itself is
-- correct -- a Rojo resync quirk, not something this codebase's own scripts
-- ever touch. That's not just cosmetic: it puts the ground's top surface at
-- Y=10 instead of Y=0, which either buries the lobby plaza inside it or (if
-- ever combined with a smaller ground) reintroduces exactly the
-- "fall-through-the-ground" risk this service's stage-bounds fix exists to
-- prevent. Corrected unconditionally at server start so a stale Edit-mode
-- drift can never reach actual players.
local EXPECTED_BASEPLATE_POSITION = Vector3.new(0, -10, 0)

local function ensureBaseplatePosition()
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") and baseplate.Position ~= EXPECTED_BASEPLATE_POSITION then
		baseplate.Position = EXPECTED_BASEPLATE_POSITION
	end
end

function StageDecorationService.Init()
	ensureBaseplatePosition()

	-- Driven off the tag rather than the stage folders, so it covers every
	-- checkpoint StageService already knows about no matter which stage (or
	-- how deeply nested) it was built under.
	for _, checkpoint in CollectionService:GetTagged("Checkpoint") do
		if checkpoint:IsA("BasePart") then
			decorateCheckpoint(checkpoint)
		end
	end
	CollectionService:GetInstanceAddedSignal("Checkpoint"):Connect(function(checkpoint)
		if checkpoint:IsA("BasePart") then
			decorateCheckpoint(checkpoint)
		end
	end)

	local stagesFolder = Workspace:FindFirstChild("Stages")
	if not stagesFolder then
		return
	end

	for _, stage in Stages do
		local palette = PALETTES[stage.Weather]
		local stageFolder = stagesFolder:FindFirstChild(stage.Id)
		if palette and stageFolder then
			decorateStage(stageFolder, palette)
		end
	end
end

return StageDecorationService
