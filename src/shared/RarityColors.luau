-- Single source of truth for rarity -> color, shared by the gacha UI
-- (GachaController) and ability-use feedback (AbilityController) so a
-- Legendary pull and a Legendary ability activation read as the same
-- "Legendary" visually, not two unrelated shades of gold picked separately.
local RarityColors: { [string]: Color3 } = {
	Common = Color3.fromRGB(172, 176, 199), -- matches Theme.Color.TextSecondary without creating a require cycle
	Rare = Color3.fromRGB(84, 160, 255),
	Epic = Color3.fromRGB(191, 110, 255),
	Legendary = Color3.fromRGB(255, 176, 59),
}

return RarityColors
