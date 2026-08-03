-- Single source of truth for rarity -> color, shared by the gacha UI
-- (GachaController) and ability-use feedback (AbilityController) so a
-- Legendary pull and a Legendary ability activation read as the same
-- "Legendary" visually, not two unrelated shades of gold picked separately.
local RarityColors: { [string]: Color3 } = {
	Common = Color3.fromRGB(172, 176, 199), -- matches Theme.Color.TextSecondary without creating a require cycle
	Rare = Color3.fromRGB(84, 160, 255),
	Epic = Color3.fromRGB(191, 110, 255),
	Legendary = Color3.fromRGB(255, 176, 59),
	-- Deliberately a hot rose-red rather than "brighter gold": Mythic sits one
	-- step above Legendary, and a lighter shade of the same hue reads as a
	-- variant of it at a glance instead of a tier above it. This is the only
	-- rarity color that isn't adjacent to any other on the wheel.
	Mythic = Color3.fromRGB(255, 78, 120),
}

return RarityColors
