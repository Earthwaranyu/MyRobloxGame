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
	-- Post-processing. These effects already existed in Lighting but were
	-- STATIC -- one fixed look shared by a sunny plaza, a thunderstorm and a
	-- midnight stage alike, which flattened the difference between them to
	-- little more than fog colour. Driving them per weather is the cheapest
	-- large visual gain available: no new geometry, no extra draw calls, and
	-- it makes each stage read as its own place in a screenshot.
	--
	-- Bloom sells emissive surfaces (the neon queue rooms, checkpoint pads,
	-- Stage3's night-time gimmicks); ColorCorrection is what actually gives a
	-- scene a "grade" instead of looking like untouched default Roblox.
	Bloom: {
		Intensity: number,
		Size: number,
		Threshold: number,
	},
	ColorCorrection: {
		Saturation: number,
		Contrast: number,
		Brightness: number,
		TintColor: Color3,
	},
	SunRays: {
		Intensity: number,
		Spread: number,
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
	-- Punchy and warm, to match the candy UI rather than fight it. Threshold
	-- sits low enough that the neon queue-room floors and the trophy actually
	-- glow, which is what makes the lobby photograph well.
	Bloom = { Intensity = 0.9, Size = 20, Threshold = 1.6 },
	ColorCorrection = {
		Saturation = 0.16,
		Contrast = 0.08,
		Brightness = 0,
		TintColor = Color3.fromRGB(255, 250, 244),
	},
	SunRays = { Intensity = 0.14, Spread = 0.9 },
	-- Chosen partly for LENGTH. The lobby is where players spend most of their
	-- time -- queueing, shopping, comparing profiles -- and the previous track
	-- was a 60-second cut, so it restarted every single minute. That is the kind
	-- of repetition nobody consciously notices and everybody eventually mutes.
	-- This one runs 189s, a bit over three times as long, so the loop point
	-- comes round far less often.
	--
	-- Kept quieter and calmer than Weather.Race below on purpose: the race track
	-- is meant to read as a step UP in energy when a stage loads, which only
	-- works if the lobby isn't already at that level.
	MusicSoundId = "rbxassetid://1845742740", -- APM Music: "Fun Gang" (189s)
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
		-- Saturated holiday-postcard look; the brightest grade of the four.
		Bloom = { Intensity = 0.85, Size = 20, Threshold = 1.8 },
		ColorCorrection = {
			Saturation = 0.2,
			Contrast = 0.06,
			Brightness = 0,
			TintColor = Color3.fromRGB(255, 252, 240),
		},
		SunRays = { Intensity = 0.18, Spread = 1 },
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
		-- Drained of colour and pushed to contrast -- the storm should feel like
		-- the colour has been sucked out of the world, not merely like fog.
		-- SunRays nearly off: there is no visible sun to cast them.
		Bloom = { Intensity = 0.45, Size = 24, Threshold = 2.2 },
		ColorCorrection = {
			Saturation = -0.28,
			Contrast = 0.14,
			Brightness = -0.02,
			TintColor = Color3.fromRGB(198, 212, 235),
		},
		SunRays = { Intensity = 0.02, Spread = 0.2 },
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
		-- Crisp and slightly cool -- clear air, hard edges, no haze glow.
		Bloom = { Intensity = 0.7, Size = 20, Threshold = 1.9 },
		ColorCorrection = {
			Saturation = 0.1,
			Contrast = 0.07,
			Brightness = 0,
			TintColor = Color3.fromRGB(246, 250, 255),
		},
		SunRays = { Intensity = 0.16, Spread = 0.8 },
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
		-- The one preset where bloom does real work: a low threshold makes every
		-- emissive surface on the stage (pads, checkpoints, the vanishing
		-- platforms' warning flash) bloom against a near-black sky, which is what
		-- makes a night stage look deliberate rather than just underlit.
		Bloom = { Intensity = 1.4, Size = 28, Threshold = 1.05 },
		ColorCorrection = {
			Saturation = -0.06,
			Contrast = 0.16,
			Brightness = 0.01,
			TintColor = Color3.fromRGB(172, 190, 255),
		},
		SunRays = { Intensity = 0, Spread = 0 },
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
