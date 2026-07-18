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

local atmosphere: Atmosphere

local function getAtmosphere(): Atmosphere
	if not atmosphere then
		atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		if not atmosphere then
			atmosphere = Instance.new("Atmosphere")
			atmosphere.Parent = Lighting
		end
	end
	return atmosphere
end

local function tweenTo(lightingProps: { [string]: any }, atmosphereProps: { [string]: any })
	local info = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	TweenService:Create(Lighting, info, lightingProps):Play()
	TweenService:Create(getAtmosphere(), info, atmosphereProps):Play()
end

function WeatherService.ApplyStageWeather(stageId: string)
	local preset = Weather.GetForStage(stageId)
	if not preset then
		return
	end
	tweenTo(preset.Lighting, preset.Atmosphere)
end

function WeatherService.RevertToLobby()
	tweenTo(Weather.Lobby.Lighting, Weather.Lobby.Atmosphere)
end

function WeatherService.Init()
	getAtmosphere()
	WeatherService.RevertToLobby()
end

return WeatherService
