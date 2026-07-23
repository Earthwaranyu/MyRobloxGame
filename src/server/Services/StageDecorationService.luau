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
	VoidColor: Color3,
}

local PALETTES: { [string]: Palette } = {
	Sunny = {
		PlatformColor = Color3.fromRGB(95, 205, 95),
		PlatformMaterial = Enum.Material.Grass,
		VoidColor = Color3.fromRGB(120, 190, 255),
	},
	Stormy = {
		PlatformColor = Color3.fromRGB(75, 95, 115),
		PlatformMaterial = Enum.Material.Slate,
		VoidColor = Color3.fromRGB(42, 52, 68),
	},
	Night = {
		PlatformColor = Color3.fromRGB(58, 42, 92),
		PlatformMaterial = Enum.Material.Slate,
		VoidColor = Color3.fromRGB(12, 10, 26),
	},
	Windy = {
		PlatformColor = Color3.fromRGB(212, 236, 246),
		PlatformMaterial = Enum.Material.SmoothPlastic,
		VoidColor = Color3.fromRGB(228, 242, 250),
	},
}

-- StartLine/FinishLine (colored wall banners) and Checkpoint_* (neon
-- markers) are functional affordances players already read at a glance --
-- left untouched so re-theming a stage never makes them harder to spot.
-- SpawnLocation is similarly left alone (not a BasePart match anyway, but
-- explicit here since it's the same "leave functional markers alone" idea).
local function isGenericPlatform(part: BasePart): boolean
	return part.Name == "VoidZone" or part.Name:match("^Platform") ~= nil
end

local function decorateStage(stageFolder: Folder, palette: Palette)
	for _, part in stageFolder:GetChildren() do
		if part:IsA("BasePart") and isGenericPlatform(part) then
			if part.Name == "VoidZone" then
				part.Color = palette.VoidColor
			else
				part.Color = palette.PlatformColor
				part.Material = palette.PlatformMaterial
			end
		end
	end
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
