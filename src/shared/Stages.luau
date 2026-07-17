export type StageInfo = {
	Id: string,
	Name: string,
}

local Stages: { StageInfo } = {
	{ Id = "Stage1", Name = "Stage 1" },
	{ Id = "Stage2", Name = "Stage 2" },
	{ Id = "Stage3", Name = "Stage 3" },
}

return Stages
