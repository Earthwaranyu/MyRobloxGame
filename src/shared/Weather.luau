local Stages = require(script.Parent.Stages)

export type WeatherPreset = {
	-- Lighting properties applied globally while this weather's stage is active.
	Lighting: {
		ClockTime: number,
		Brightness: number,
		Ambient: Color3,
		OutdoorAmbient: Color3,
		FogColor: Color3,
		FogStart: number,
		FogEnd: number,
	},
	-- Lighting.Atmosphere properties, same idea.
	Atmosphere: {
		Density: number,
		Offset: number,
		Color: Color3,
		Decay: Color3,
		Glare: number,
		Haze: number,
	},
	-- Looping ambient bed, e.g. birdsong or rain, played on loop while racing.
	AmbientSoundId: string,
	AmbientVolume: number,
	-- Optional one-shot layered on top at random intervals (thunder, owl hoot).
	AccentSoundId: string?,
	AccentVolume: number?,
	AccentIntervalMin: number?,
	AccentIntervalMax: number?,
}

local Weather = {}

-- Bright, warm, welcoming -- the mood while players are just hanging out
-- before queueing, independent of whichever stage last had the spotlight.
Weather.Lobby = {
	Lighting = {
		ClockTime = 15,
		Brightness = 3,
		Ambient = Color3.fromRGB(90, 90, 110),
		OutdoorAmbient = Color3.fromRGB(140, 150, 165),
		FogColor = Color3.fromRGB(180, 200, 225),
		FogStart = 400,
		FogEnd = 4000,
	},
	Atmosphere = {
		Density = 0.25,
		Offset = 0.25,
		Color = Color3.fromRGB(199, 199, 199),
		Decay = Color3.fromRGB(106, 138, 173),
		Glare = 0.15,
		Haze = 1,
	},
	MusicSoundId = "rbxassetid://9038571008",
	MusicVolume = 0.4,
}

Weather.Presets = {
	Sunny = {
		Lighting = {
			ClockTime = 14,
			Brightness = 3.2,
			Ambient = Color3.fromRGB(110, 110, 120),
			OutdoorAmbient = Color3.fromRGB(160, 170, 180),
			FogColor = Color3.fromRGB(190, 215, 235),
			FogStart = 600,
			FogEnd = 6000,
		},
		Atmosphere = {
			Density = 0.2,
			Offset = 0.25,
			Color = Color3.fromRGB(199, 199, 199),
			Decay = Color3.fromRGB(92, 150, 173),
			Glare = 0.25,
			Haze = 0.8,
		},
		AmbientSoundId = "rbxassetid://9112831284", -- Morning Birds
		AmbientVolume = 0.3,
	} :: WeatherPreset,

	Stormy = {
		Lighting = {
			ClockTime = 13,
			Brightness = 1,
			Ambient = Color3.fromRGB(55, 58, 66),
			OutdoorAmbient = Color3.fromRGB(70, 75, 85),
			FogColor = Color3.fromRGB(90, 96, 104),
			FogStart = 40,
			FogEnd = 500,
		},
		Atmosphere = {
			Density = 0.6,
			Offset = 0.15,
			Color = Color3.fromRGB(130, 130, 130),
			Decay = Color3.fromRGB(65, 68, 74),
			Glare = 0,
			Haze = 6,
		},
		AmbientSoundId = "rbxassetid://9112854469", -- Rain On Water
		AmbientVolume = 0.45,
		AccentSoundId = "rbxassetid://9120015808", -- Thunder And Rain
		AccentVolume = 0.55,
		AccentIntervalMin = 18,
		AccentIntervalMax = 38,
	} :: WeatherPreset,

	Night = {
		Lighting = {
			ClockTime = 0,
			Brightness = 0.6,
			Ambient = Color3.fromRGB(35, 40, 60),
			OutdoorAmbient = Color3.fromRGB(40, 48, 70),
			FogColor = Color3.fromRGB(15, 18, 30),
			FogStart = 60,
			FogEnd = 900,
		},
		Atmosphere = {
			Density = 0.4,
			Offset = 0.25,
			Color = Color3.fromRGB(140, 150, 180),
			Decay = Color3.fromRGB(20, 25, 45),
			Glare = 0,
			Haze = 2.2,
		},
		AmbientSoundId = "rbxassetid://9112764040", -- Crickets Canyon
		AmbientVolume = 0.32,
		AccentSoundId = "rbxassetid://9117182187", -- Owl Hooting
		AccentVolume = 0.4,
		AccentIntervalMin = 22,
		AccentIntervalMax = 45,
	} :: WeatherPreset,
}

function Weather.GetForStage(stageId: string): WeatherPreset?
	for _, stage in Stages do
		if stage.Id == stageId then
			return Weather.Presets[stage.Weather]
		end
	end
	return nil
end

return Weather
