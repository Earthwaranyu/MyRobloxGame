local EloCalculator = {}

local function expectedScore(ratingA: number, ratingB: number): number
	return 1 / (1 + 10 ^ ((ratingB - ratingA) / 400))
end

function EloCalculator.CalculateNewRatings(winnerRating: number, loserRating: number, kFactor: number): (number, number)
	local expectedWinner = expectedScore(winnerRating, loserRating)
	local expectedLoser = expectedScore(loserRating, winnerRating)

	local newWinnerRating = winnerRating + kFactor * (1 - expectedWinner)
	local newLoserRating = math.max(0, loserRating + kFactor * (0 - expectedLoser))

	return math.round(newWinnerRating), math.round(newLoserRating)
end

return EloCalculator
