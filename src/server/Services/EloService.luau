local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local EloCalculator = require(Shared.EloCalculator)

local PlayerDataService = require(script.Parent.PlayerDataService)
local OverheadDisplayService = require(script.Parent.OverheadDisplayService)

local EloService = {}

-- Call this once a race's winner/loser is determined by matchmaking logic.
function EloService.ReportMatchResult(winner: Player, loser: Player)
	local winnerProfile = PlayerDataService.GetProfile(winner)
	local loserProfile = PlayerDataService.GetProfile(loser)

	if not winnerProfile or not loserProfile then
		return
	end

	local newWinnerElo, newLoserElo =
		EloCalculator.CalculateNewRatings(winnerProfile.Elo, loserProfile.Elo, Constants.Elo.KFactor)

	winnerProfile.Elo = newWinnerElo
	loserProfile.Elo = newLoserElo
	winnerProfile.Points += Constants.Match.PointsPerWin

	OverheadDisplayService.Refresh(winner)
	OverheadDisplayService.Refresh(loser)
end

return EloService
