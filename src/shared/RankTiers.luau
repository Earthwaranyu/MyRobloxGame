export type RankTier = {
	Name: string,
	MinElo: number,
	Color: Color3,
}

local RankTiers = {}

-- Ascending by MinElo; adjust freely, the lookup functions don't assume specific values.
RankTiers.Tiers = {
	{ Name = "Bronze", MinElo = 0, Color = Color3.fromRGB(205, 127, 80) },
	{ Name = "Silver", MinElo = 500, Color = Color3.fromRGB(198, 205, 216) },
	{ Name = "Gold", MinElo = 1000, Color = Color3.fromRGB(255, 209, 102) },
	{ Name = "Platinum", MinElo = 1500, Color = Color3.fromRGB(126, 224, 224) },
	{ Name = "Diamond", MinElo = 2000, Color = Color3.fromRGB(108, 178, 255) },
	{ Name = "Master", MinElo = 2500, Color = Color3.fromRGB(191, 110, 255) },
	{ Name = "Grandmaster", MinElo = 3000, Color = Color3.fromRGB(255, 92, 122) },
}

function RankTiers.GetTierForElo(elo: number): RankTier
	local tier = RankTiers.Tiers[1]
	for _, t in RankTiers.Tiers do
		if elo >= t.MinElo then
			tier = t
		else
			break
		end
	end
	return tier
end

function RankTiers.GetRankForElo(elo: number): string
	return RankTiers.GetTierForElo(elo).Name
end

function RankTiers.GetColorForElo(elo: number): Color3
	return RankTiers.GetTierForElo(elo).Color
end

function RankTiers.GetColorForRank(rankName: string): Color3?
	for _, tier in RankTiers.Tiers do
		if tier.Name == rankName then
			return tier.Color
		end
	end
	return nil
end

return RankTiers
