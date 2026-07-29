export type RankTier = {
	Name: string,
	MinElo: number,
	Color: Color3,
}

local RankTiers = {}

-- Ascending by MinElo; adjust freely, the lookup functions don't assume specific values.
--
-- Anchored to Constants.Elo.StartingRating (1000), which sits inside BRONZE --
-- the rank players start at and climb from, which is the progression the ladder
-- is meant to read as.
--
-- The separate thing the start has to satisfy is that it must not sit ON the
-- rating floor. It used to (start 0, floor 0), and a player standing on the
-- floor cannot lose -- every loss clamps straight back, so finishing last cost
-- nothing and placement Elo was a no-op at the bottom. Starting at 1000 leaves
-- a thousand points of room beneath the start, so a loss always costs something
-- real from the very first race.
--
-- IRON sits below Bronze to catch that slide. Without it Bronze had to be both
-- "just started" and "lost a great many races", which are not the same standing
-- and shouldn't wear the same badge -- and a losing streak showed up nowhere,
-- since there was no rank to fall to. Bronze is now a real band (800..1199)
-- with the 1000 start in the middle of it: roughly 13 net wins to Silver, and
-- about as many net losses to Iron, so the rank moves in both directions at a
-- similar pace.
--
-- Iron is the wide one instead (0..799), which is the right place for the slack:
-- it is the bottom of the ladder, nobody starts there, and there is nothing
-- below it to be demoted to.
--
-- The bands above widen as they go (250, 300, 350, 400, 500) so early promotions
-- come quickly and the top ranks stay scarce.
RankTiers.Tiers = {
	{ Name = "Iron", MinElo = 0, Color = Color3.fromRGB(122, 128, 138) },
	{ Name = "Bronze", MinElo = 800, Color = Color3.fromRGB(205, 127, 80) },
	{ Name = "Silver", MinElo = 1200, Color = Color3.fromRGB(198, 205, 216) },
	{ Name = "Gold", MinElo = 1450, Color = Color3.fromRGB(255, 209, 102) },
	{ Name = "Platinum", MinElo = 1750, Color = Color3.fromRGB(126, 224, 224) },
	{ Name = "Diamond", MinElo = 2100, Color = Color3.fromRGB(108, 178, 255) },
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
