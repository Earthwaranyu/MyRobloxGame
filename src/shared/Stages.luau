export type Difficulty = "Easy" | "Medium" | "Hard"
export type WeatherKind = "Sunny" | "Windy" | "Night" | "Stormy" | "Cloudy"

-- Each stage gets ONE signature moving-part mechanic (see StageGimmickService)
-- so the four courses actually play differently instead of just being
-- re-skinned copies of the same static jumps. The kind maps to the stage's
-- theme: bouncy & forgiving for the easy sunny opener, escalating to
-- collapsing platforms on the hard night stage.
--   Bounce   -- pads that launch you up & forward (playful, low risk)
--   Moving   -- platforms that slide side-to-side; jump when they line up
--   Vanishing-- platforms that fade out then drop away on a timed cycle
--   Speed    -- floor strips that grant a short forward speed surge
export type GimmickKind = "Bounce" | "Moving" | "Vanishing" | "Speed"

export type StageInfo = {
	Id: string,
	Name: string,
	Difficulty: Difficulty,
	Weather: WeatherKind,
	Gimmick: GimmickKind,
	-- true = the course geometry is generated at server start from
	-- StageLayout's plan (see StageBuilderService) instead of being hand-built
	-- in Studio and living in the .rbxl. Stage1-4 predate that and are
	-- hand-built, which is why this is opt-in rather than the default: the
	-- builder must never draw a second course on top of one that already
	-- exists in the place file.
	Generated: boolean?,
}

-- Difficulty spread is deliberate: 2 Easy / 3 Medium / 3 Hard, so a random
-- roll lands on a punishing course less than half the time. No
-- weather+gimmick PAIR repeats either -- with 5 weathers and 4 gimmicks
-- there's no need to reuse one, and a repeated pair is the thing that makes
-- two stages feel like the same stage twice.
local Stages: { StageInfo } = {
	{ Id = "Stage1", Name = "Stage 1", Difficulty = "Easy", Weather = "Sunny", Gimmick = "Bounce" },
	{ Id = "Stage2", Name = "Stage 2", Difficulty = "Medium", Weather = "Stormy", Gimmick = "Moving" },
	{ Id = "Stage3", Name = "Stage 3", Difficulty = "Hard", Weather = "Night", Gimmick = "Vanishing" },
	{ Id = "Stage4", Name = "Stage 4", Difficulty = "Medium", Weather = "Windy", Gimmick = "Speed" },
	{ Id = "Stage5", Name = "Stage 5", Difficulty = "Easy", Weather = "Cloudy", Gimmick = "Bounce", Generated = true },
	{ Id = "Stage6", Name = "Stage 6", Difficulty = "Medium", Weather = "Sunny", Gimmick = "Speed", Generated = true },
	{ Id = "Stage7", Name = "Stage 7", Difficulty = "Hard", Weather = "Stormy", Gimmick = "Vanishing", Generated = true },
	{ Id = "Stage8", Name = "Stage 8", Difficulty = "Hard", Weather = "Night", Gimmick = "Moving", Generated = true },
}

return Stages
