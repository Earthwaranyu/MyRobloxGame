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
	-- Optional one-shot layered on top of the race music at random intervals
	-- (thunder, owl hoot) -- the only audio a WeatherPreset drives now, since
	-- Weather.Race's music track replaced the old continuous ambient bed.
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
	MusicSoundId = "rbxassetid://9043769892", -- APM Music: "Throw Your Hands in the Air (c 60)"
	MusicVolume = 0.4,
}

-- Plays instead of the stage's weather ambience while "Racing" (see
-- AmbienceController) -- a deliberate step up in energy from Lobby's own
-- track once the player actually loads into a stage.
Weather.Race = {
	MusicSoundId = "rbxassetid://9043277248", -- APM Music: "Race Machine"
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
		AccentSoundId = "rbxassetid://9120015808", -- Thunder And Rain
		AccentVolume = 0.55,
		AccentIntervalMin = 18,
		AccentIntervalMax = 38,
	} :: WeatherPreset,

	Windy = {
		Lighting = {
			ClockTime = 12,
			Brightness = 2.7,
			Ambient = Color3.fromRGB(128, 128, 118),
			OutdoorAmbient = Color3.fromRGB(168, 168, 152),
			FogColor = Color3.fromRGB(198, 193, 172),
			FogStart = 100,
			FogEnd = 1800,
		},
		Atmosphere = {
			Density = 0.45,
			Offset = 0.2,
			Color = Color3.fromRGB(208, 202, 182),
			Decay = Color3.fromRGB(148, 138, 108),
			Glare = 0.1,
			Haze = 4,
		},
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
