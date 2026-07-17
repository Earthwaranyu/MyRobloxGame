export type RankTier = {
	Name: string,
	MinElo: number,
}

local RankTiers = {}

-- Ascending by MinElo; adjust freely, GetRankForElo doesn't assume specific values.
RankTiers.Tiers = {
	{ Name = "Bronze", MinElo = 0 },
	{ Name = "Silver", MinElo = 500 },
	{ Name = "Gold", MinElo = 1000 },
	{ Name = "Platinum", MinElo = 1500 },
	{ Name = "Diamond", MinElo = 2000 },
	{ Name = "Master", MinElo = 2500 },
	{ Name = "Grandmaster", MinElo = 3000 },
}

function RankTiers.GetRankForElo(elo: number): string
	local rank = RankTiers.Tiers[1].Name
	for _, tier in RankTiers.Tiers do
		if elo >= tier.MinElo then
			rank = tier.Name
		else
			break
		end
	end
	return rank
end

return RankTiers
