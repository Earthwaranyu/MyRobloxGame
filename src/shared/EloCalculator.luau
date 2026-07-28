local EloCalculator = {}

local function expectedScore(ratingA: number, ratingB: number): number
	return 1 / (1 + 10 ^ ((ratingB - ratingA) / 400))
end

-- Rating change for each side, with an INDEPENDENT K per side.
--
-- Textbook Elo uses one K for both, keeping the exchange zero-sum. This game
-- deliberately breaks that symmetry so a result can be worth a normal amount to
-- one player and very little to the other -- specifically, beating a day-old
-- account should barely move an established player while still moving the
-- newcomer normally (see MatchService's account-age weighting).
--
-- Zero-sum was never actually preserved here anyway: the loser is floored at 0,
-- so every result against a drained opponent has always been asymmetric.
function EloCalculator.CalculateDeltas(
	winnerRating: number,
	loserRating: number,
	kWinner: number,
	kLoser: number
): (number, number)
	local expectedWinner = expectedScore(winnerRating, loserRating)
	local expectedLoser = expectedScore(loserRating, winnerRating)

	return kWinner * (1 - expectedWinner), kLoser * (0 - expectedLoser)
end

function EloCalculator.CalculateNewRatings(winnerRating: number, loserRating: number, kFactor: number): (number, number)
	local winnerDelta, loserDelta = EloCalculator.CalculateDeltas(winnerRating, loserRating, kFactor, kFactor)

	-- The 0 floor is load-bearing beyond just "ratings shouldn't be negative":
	-- it's what stops alt-farming from running away, since a drained opponent
	-- has nothing further to give and the winner's expected score against 0
	-- approaches 1 (so the gain rounds to nothing). Any future move to a
	-- floorless system -- TrueSkill, OpenSkill -- has to replace this
	-- protection deliberately rather than inherit it.
	return math.round(winnerRating + winnerDelta), math.round(math.max(0, loserRating + loserDelta))
end

return EloCalculator
