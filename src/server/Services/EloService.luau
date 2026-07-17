local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local EloCalculator = require(Shared.EloCalculator)

local PlayerDataService = require(script.Parent.PlayerDataService)
local OverheadDisplayService = require(script.Parent.OverheadDisplayService)

local EloService = {}

-- Call this once a race's winner/loser is determined by matchmaking logic.
-- Returns (winnerDelta, loserDelta) so callers can report the change to players.
function EloService.ReportMatchResult(winner: Player, loser: Player): (number, number)
	local winnerProfile = PlayerDataService.GetProfile(winner)
	local loserProfile = PlayerDataService.GetProfile(loser)

	if not winnerProfile or not loserProfile then
		return 0, 0
	end

	local oldWinnerElo = winnerProfile.Elo
	local oldLoserElo = loserProfile.Elo

	local newWinnerElo, newLoserElo =
		EloCalculator.CalculateNewRatings(winnerProfile.Elo, loserProfile.Elo, Constants.Elo.KFactor)

	winnerProfile.Elo = newWinnerElo
	loserProfile.Elo = newLoserElo

	OverheadDisplayService.Refresh(winner)
	OverheadDisplayService.Refresh(loser)

	return newWinnerElo - oldWinnerElo, newLoserElo - oldLoserElo
end

return EloService
