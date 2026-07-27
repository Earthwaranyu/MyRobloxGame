export type Difficulty = "Easy" | "Medium" | "Hard"
export type WeatherKind = "Sunny" | "Windy" | "Night" | "Stormy"

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
}

local Stages: { StageInfo } = {
	{ Id = "Stage1", Name = "Stage 1", Difficulty = "Easy", Weather = "Sunny", Gimmick = "Bounce" },
	{ Id = "Stage2", Name = "Stage 2", Difficulty = "Medium", Weather = "Stormy", Gimmick = "Moving" },
	{ Id = "Stage3", Name = "Stage 3", Difficulty = "Hard", Weather = "Night", Gimmick = "Vanishing" },
	{ Id = "Stage4", Name = "Stage 4", Difficulty = "Medium", Weather = "Windy", Gimmick = "Speed" },
}

return Stages
