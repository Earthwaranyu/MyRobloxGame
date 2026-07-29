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

	-- A backstop, not a balancing mechanism. It used to be load-bearing, back
	-- when players started AT 0 -- but that also meant a new player could never
	-- lose rating, so the start moved to Constants.Elo.StartingRating and the
	-- floor stopped being the thing anyone actually touches.
	--
	-- What limits repeated wins over one opponent now is the RATING GAP, which
	-- binds first: the pair converges about 720 points apart (1360 vs 640 from
	-- an even start), at which point the winner's expected score is high enough
	-- that further gains round to nothing. The deliberate protections are
	-- MatchService's rematch decay and account-age weighting; neither depends on
	-- this clamp.
	return math.round(winnerRating + winnerDelta), math.round(math.max(0, loserRating + loserDelta))
end

return EloCalculator
