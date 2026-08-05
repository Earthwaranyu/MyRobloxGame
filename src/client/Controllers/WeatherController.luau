local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Weather = require(Shared.Weather)

-- Applies THIS player's stage weather to THIS client's Lighting.
--
-- All of the tweening below used to live on the server (WeatherService), which
-- worked only while a single race could exist at a time. Races now run in
-- parallel and a Roblox server has one Lighting, so the server can't hold a
-- value that's correct for a group on the storm stage and a group on the night
-- stage at once. Client-side Lighting writes are purely local, so each player
-- can see their own stage's sky with no conflict -- and the server no longer
-- touches Lighting at all, so nothing replicates down to overwrite this.
local WeatherController = {}

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
	TweenService:Create(effect("Atmosphere"), info, atmosphereProps):Play()
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

local function applyLobby()
	tweenTo(
		Weather.Lobby.Lighting,
		Weather.Lobby.Atmosphere,
		Weather.Lobby.Bloom,
		Weather.Lobby.ColorCorrection,
		Weather.Lobby.SunRays
	)
end

-- `overrideName` is a private-server host's pinned sky (see WeatherService). It
-- beats both the stage's own weather AND the lobby look, so the host can see
-- what they picked from where they picked it. An unrecognised name falls
-- through to normal behaviour rather than blanking the sky.
function WeatherController.Apply(stageId: string?, overrideName: string?)
	local preset = Weather.GetByName(overrideName)
	if not preset then
		if not stageId then
			applyLobby()
			return
		end
		preset = Weather.GetForStage(stageId)
	end
	if not preset then
		-- An unknown stage leaves the current look alone rather than snapping
		-- to the lobby: whatever is on screen is at least a deliberate preset.
		return
	end
	tweenTo(preset.Lighting, preset.Atmosphere, preset.Bloom, preset.ColorCorrection, preset.SunRays)
end

function WeatherController.Init()
	effect("Atmosphere")
	applyLobby()

	Net.GetRemoteEvent(RemoteNames.WeatherChanged).OnClientEvent:Connect(
		function(stageId: string?, overrideName: string?)
			WeatherController.Apply(stageId, overrideName)
		end
	)
end

return WeatherController
