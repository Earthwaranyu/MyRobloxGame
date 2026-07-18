-- Central design tokens so every panel/button/label shares one visual language.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RankTiers = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RankTiers"))

local Theme = {}

Theme.Color = {
	Background = Color3.fromRGB(15, 16, 22),
	Panel = Color3.fromRGB(26, 27, 38),
	PanelLight = Color3.fromRGB(34, 36, 50),
	Stroke = Color3.fromRGB(72, 76, 110),

	AccentA = Color3.fromRGB(88, 101, 242), -- gradient start (blurple)
	AccentB = Color3.fromRGB(168, 85, 247), -- gradient end (violet)

	Success = Color3.fromRGB(87, 242, 135),
	Danger = Color3.fromRGB(255, 92, 108),
	Warning = Color3.fromRGB(255, 196, 61),

	TextPrimary = Color3.fromRGB(245, 245, 250),
	TextSecondary = Color3.fromRGB(172, 176, 199),
	TextMuted = Color3.fromRGB(120, 124, 148),
}

Theme.Font = {
	Display = Enum.Font.GothamBlack,
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.Gotham,
}

Theme.Corner = {
	Panel = UDim.new(0, 14),
	Button = UDim.new(0, 16),
	Pill = UDim.new(1, 0),
}

Theme.Anim = {
	Fast = 0.12,
	Medium = 0.22,
	Slow = 0.4,
	Pop = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Ease = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Smooth = TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
}

function Theme.GetRankColor(rankName: string): Color3
	return RankTiers.GetColorForRank(rankName) or Theme.Color.TextPrimary
end

return Theme
