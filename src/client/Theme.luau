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

-- The top-centre HUD lane, shared because FOUR controllers draw into it and
-- each had hand-copied its neighbours' numbers into its own comments:
-- WaveClockController's wave tab, QueueStatusController's countdown card (whose
-- cancel X straddles the card's top edge, hanging CardOverhang above it),
-- RaceHudController's race timer, and QuitMatchController's Leave Match button
-- sitting beside them.
--
-- Copied numbers is precisely how the lane broke. The wave tab was 32px tall
-- when the card's y was chosen against it; the tab later grew to 44 and the
-- card never moved, so the card's cancel X ended up inside the tab's rows and
-- missed it only because their x-ranges happened to abut exactly. The Leave
-- Match button had it worse: it was placed to clear the RACE timer (240 wide),
-- but during the pre-race countdown the neighbour is the CARD (300 wide), so it
-- was drawn 10px over the card's right border -- which is what you see on
-- screen during "RACE STARTING IN".
--
-- So the lane is one set of numbers now, and the two derived positions below
-- are derived once rather than in each controller.
Theme.TopLane = {
	TabWidth = 264,
	TabHeight = 44,
	-- Clear of the Roblox topbar: these ScreenGuis keep the default inset.
	TabTop = 6,
	CardWidth = 300,
	-- The countdown card's own height. Lived as a bare 104 inside
	-- QueueStatusController until something needed to stack BELOW the card
	-- (QuitMatchController does, on phones, where there is no room beside it) --
	-- at which point it was a number two controllers had to agree on, which is
	-- the exact condition this table exists for.
	CardHeight = 104,
	-- The card's cancel X is centred ON its top-right corner, so it hangs this
	-- far past the card's edge both upward and to the right -- half the button,
	-- and the reason one constant covers both directions.
	CardOverhang = 18,
	-- Air between anything in this lane and anything next to it, stacked or
	-- side by side, so the lane keeps one rhythm.
	Gap = 14,
}

-- Below the tab with the card's overhanging cancel X counted in, not just the
-- card's own edge -- the overhang is the part that actually collides.
Theme.TopLane.CardTop = Theme.TopLane.TabTop + Theme.TopLane.TabHeight + Theme.TopLane.Gap + Theme.TopLane.CardOverhang
-- X offset from screen centre for anything parked BESIDE the lane. Measured off
-- the card because it is the widest thing that can be there (clearing it clears
-- the narrower race timer too), and off the cancel X rather than the card's own
-- edge, since the X is what actually sticks out furthest. The X and the Leave
-- Match button are never on screen at the same time as things stand -- but
-- "these two happen not to coincide today" is the assumption that put the
-- button on top of the card in the first place.
Theme.TopLane.SideOffset = Theme.TopLane.CardWidth / 2 + Theme.TopLane.CardOverhang + Theme.TopLane.Gap

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
