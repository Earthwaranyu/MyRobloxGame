export type Trail = {
	Name: string,
	PointsCost: number,
	RobuxProductId: number?,
	HasEffect: boolean,
	Color: ColorSequence?,
	Width0: number?,
	Width1: number?,
}

local Trails: { [string]: Trail } = {
	Basic = {
		Name = "Basic Trail",
		PointsCost = 0,
		HasEffect = false,
	},
	Flame = {
		Name = "Flame Trail",
		PointsCost = 500,
		HasEffect = true,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 221, 120)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 120, 40)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 20, 10)),
		}),
		Width0 = 1.6,
		Width1 = 0,
	},
	Rainbow = {
		Name = "Rainbow Trail",
		PointsCost = 1500,
		HasEffect = true,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 60)),
			ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 165, 0)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 200, 90)),
			ColorSequenceKeypoint.new(0.67, Color3.fromRGB(30, 140, 255)),
			ColorSequenceKeypoint.new(0.83, Color3.fromRGB(120, 60, 220)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 170)),
		}),
		Width0 = 1.4,
		Width1 = 0,
	},
}

return Trails
