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

-- "Candy" palette: the bright, chunky, white-bordered mobile-game look every
-- button/panel in the game was reskinned to (see Widgets.Button/Panel/Modal).
-- Every entry is a Face/Shadow pair -- Shadow is the same hue darkened, used
-- for the bevel strip along a button's bottom edge and a panel's drop-shadow,
-- never a random unrelated color, so the "3D toy" look reads as one coherent
-- material rather than mismatched layers.
Theme.Candy = {
	Purple = { Face = Color3.fromRGB(124, 88, 224), Shadow = Color3.fromRGB(74, 48, 156) },
	PurpleDeep = { Face = Color3.fromRGB(88, 58, 176), Shadow = Color3.fromRGB(52, 32, 114) },
	Green = { Face = Color3.fromRGB(97, 209, 84), Shadow = Color3.fromRGB(53, 148, 55) },
	Blue = { Face = Color3.fromRGB(66, 176, 239), Shadow = Color3.fromRGB(36, 122, 181) },
	Pink = { Face = Color3.fromRGB(255, 121, 176), Shadow = Color3.fromRGB(207, 66, 128) },
	Red = { Face = Color3.fromRGB(255, 97, 97), Shadow = Color3.fromRGB(205, 54, 59) },
	Gold = { Face = Color3.fromRGB(255, 199, 60), Shadow = Color3.fromRGB(219, 152, 28) },
	Teal = { Face = Color3.fromRGB(53, 213, 194), Shadow = Color3.fromRGB(27, 155, 145) },
	White = { Face = Color3.fromRGB(255, 255, 255), Shadow = Color3.fromRGB(205, 205, 220) },
	-- Panel fill/backdrop -- a muted violet rather than a saturated button
	-- color, so cards/buttons sitting on top of it still pop.
	PanelFace = Color3.fromRGB(107, 86, 214),
	PanelFaceLight = Color3.fromRGB(126, 106, 227),
	PanelShadow = Color3.fromRGB(64, 48, 138),
	Border = Color3.fromRGB(255, 255, 255),
	TextOutline = Color3.fromRGB(40, 26, 82),
}

Theme.Font = {
	Display = Enum.Font.GothamBlack,
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.Gotham,
	-- FredokaOne (a novelty display font) looked soft/hard-to-read at small
	-- button sizes -- Gotham is Roblox's own UI font family and stays crisp
	-- at any size, so buttons use its boldest cut instead. "Cartoony" now
	-- comes from the pill shape/outline/bounce, not the letterforms.
	Button = Enum.Font.GothamBlack,
}

Theme.Corner = {
	Panel = UDim.new(0, 24),
	Button = UDim.new(1, 0),
	Pill = UDim.new(1, 0),
	Card = UDim.new(0, 18),
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
