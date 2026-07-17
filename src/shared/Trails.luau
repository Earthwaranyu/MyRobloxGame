export type Trail = {
	Name: string,
	PointsCost: number,
	RobuxProductId: number?,
}

local Trails: { [string]: Trail } = {
	Basic = { Name = "Basic Trail", PointsCost = 0 },
	Flame = { Name = "Flame Trail", PointsCost = 500 },
	Rainbow = { Name = "Rainbow Trail", PointsCost = 1500 },
}

return Trails
