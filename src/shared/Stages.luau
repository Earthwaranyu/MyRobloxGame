export type Difficulty = "Easy" | "Medium" | "Hard"
export type WeatherKind = "Sunny" | "Windy" | "Night" | "Stormy"

export type StageInfo = {
	Id: string,
	Name: string,
	Difficulty: Difficulty,
	Weather: WeatherKind,
}

local Stages: { StageInfo } = {
	{ Id = "Stage1", Name = "Stage 1", Difficulty = "Easy", Weather = "Sunny" },
	{ Id = "Stage2", Name = "Stage 2", Difficulty = "Medium", Weather = "Stormy" },
	{ Id = "Stage3", Name = "Stage 3", Difficulty = "Hard", Weather = "Night" },
	{ Id = "Stage4", Name = "Stage 4", Difficulty = "Medium", Weather = "Windy" },
}

return Stages
