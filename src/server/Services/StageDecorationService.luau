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

function StageDecorationService.Init()
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
