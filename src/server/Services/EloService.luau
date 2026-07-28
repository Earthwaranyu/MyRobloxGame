local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local EloCalculator = require(Shared.EloCalculator)

local PlayerDataService = require(script.Parent.PlayerDataService)
local OverheadDisplayService = require(script.Parent.OverheadDisplayService)

local EloService = {}

-- Call this once a race's winner/loser is determined by matchmaking logic.
-- Returns (winnerDelta, loserDelta) so callers can report the change to players.
--
-- `winnerWeight` / `loserWeight` (0..1, default 1) scale the K-factor for each
-- side independently. Callers use them to damp results that shouldn't count for
-- full value -- repeated wins over the same opponent, and results involving
-- brand-new accounts (see MatchService's rematch decay and account-age ramp).
--
-- Per-side rather than one shared weight so the damping can be aimed: beating a
-- day-old alt is worth almost nothing to an established player, while the
-- newcomer's own rating still moves normally so real new players calibrate at
-- the usual speed.
function EloService.ReportMatchResult(
	winner: Player,
	loser: Player,
	winnerWeight: number?,
	loserWeight: number?
): (number, number)
	local winnerProfile = PlayerDataService.GetProfile(winner)
	local loserProfile = PlayerDataService.GetProfile(loser)

	if not winnerProfile or not loserProfile then
		return 0, 0
	end

	local oldWinnerElo = winnerProfile.Elo
	local oldLoserElo = loserProfile.Elo

	local k = Constants.Elo.KFactor
	local winnerDelta, loserDelta = EloCalculator.CalculateDeltas(
		winnerProfile.Elo,
		loserProfile.Elo,
		k * math.clamp(winnerWeight or 1, 0, 1),
		k * math.clamp(loserWeight or 1, 0, 1)
	)

	-- Floored at 0 -- see EloCalculator.CalculateNewRatings for why that floor
	-- matters beyond tidiness.
	local newWinnerElo = math.round(winnerProfile.Elo + winnerDelta)
	local newLoserElo = math.round(math.max(0, loserProfile.Elo + loserDelta))

	winnerProfile.Elo = newWinnerElo
	loserProfile.Elo = newLoserElo

	OverheadDisplayService.Refresh(winner)
	OverheadDisplayService.Refresh(loser)

	return newWinnerElo - oldWinnerElo, newLoserElo - oldLoserElo
end

return EloService
