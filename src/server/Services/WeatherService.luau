local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Weather = require(Shared.Weather)

-- Lighting/Atmosphere are DataModel singletons that replicate to every
-- client automatically, no remotes needed. That's only correct because the
-- whole architecture runs one active race session at a time (see
-- MatchService's single `activeSession`) -- there's never a moment where two
-- different stages' weather would need to be visible to two different
-- groups of players simultaneously.
local WeatherService = {}

local TWEEN_TIME = 3

-- Reuses whatever is already in Lighting (the place has a hand-authored Sky,
-- Atmosphere, Bloom, SunRays and DepthOfField) and only creates what's
-- missing, so a look tuned in Studio isn't silently replaced at runtime.
local cached: { [string]: Instance } = {}

local function effect(className: string): Instance
	local existing = cached[className]
	if existing and existing.Parent == Lighting then
		return existing
	end
	local found = Lighting:FindFirstChildOfClass(className)
	if not found then
		found = Instance.new(className)
		found.Parent = Lighting
	end
	cached[className] = found
	return found
end

local function getAtmosphere(): Atmosphere
	return effect("Atmosphere") :: Atmosphere
end

-- Post-processing is tweened on the same clock as the lighting itself, so a
-- stage transition is one continuous 3-second grade rather than the colour
-- snapping while the fog drifts. Each preset table is optional -- a preset
-- that omits one simply leaves that effect untouched.
local function tweenTo(
	lightingProps: { [string]: any },
	atmosphereProps: { [string]: any },
	bloomProps: { [string]: any }?,
	colorProps: { [string]: any }?,
	sunRaysProps: { [string]: any }?
)
	local info = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	TweenService:Create(Lighting, info, lightingProps):Play()
	TweenService:Create(getAtmosphere(), info, atmosphereProps):Play()
	if bloomProps then
		TweenService:Create(effect("BloomEffect"), info, bloomProps):Play()
	end
	if colorProps then
		TweenService:Create(effect("ColorCorrectionEffect"), info, colorProps):Play()
	end
	if sunRaysProps then
		TweenService:Create(effect("SunRaysEffect"), info, sunRaysProps):Play()
	end
end

function WeatherService.ApplyStageWeather(stageId: string)
	local preset = Weather.GetForStage(stageId)
	if not preset then
		return
	end
	tweenTo(preset.Lighting, preset.Atmosphere, preset.Bloom, preset.ColorCorrection, preset.SunRays)
end

function WeatherService.RevertToLobby()
	tweenTo(
		Weather.Lobby.Lighting,
		Weather.Lobby.Atmosphere,
		Weather.Lobby.Bloom,
		Weather.Lobby.ColorCorrection,
		Weather.Lobby.SunRays
	)
end

function WeatherService.Init()
	getAtmosphere()
	WeatherService.RevertToLobby()
end

return WeatherService
