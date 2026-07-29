local EloCalculator = require(script.Parent.EloCalculator)

-- The rating rules for a race, with nothing else attached.
--
-- This is deliberately pure: no Player objects, no profiles, no remotes, no
-- services. Feed it numbers and it returns numbers. MatchService keeps every
-- side effect (writing profiles, refreshing leaderstats, firing outcomes) and
-- calls in here for the decision.
--
-- The reason it's split out at all is testability. Settling a race needs N real
-- Player instances, and Player isn't a creatable class -- the only way to get
-- four of them is Studio's multi-client mode, which can't be driven
-- programmatically. So the placement rules could only ever be checked by hand,
-- across four windows, one run at a time. Pulled out here, the exact code that
-- ships can be exercised for any field size in a single call.
local RaceSettlement = {}

-- One racer's state at the moment settlement happens.
--
-- AgeWeight is MatchService's account-age ramp (0 for a brand-new account, 1
-- once established). RematchWeight is how much this specific pairing is still
-- worth to the winner after repeat wins; it belongs to the pair, not the
-- player, which is why it lives on the loser entry in a settlement rather than
-- on the racer.
export type Racer = {
	UserId: number,
	Rating: number,
	AgeWeight: number,
}

export type Opponent = {
	UserId: number,
	Rating: number,
	AgeWeight: number,
	-- 0..1, already consumed from the caller's rematch history. Passed in
	-- rather than computed here because consuming it ADVANCES a counter --
	-- a pure function must not have that side effect, and asking twice for
	-- one pair would count a single race as two.
	RematchWeight: number,
}

export type Result = {
	-- Rating change for the finisher, summed across every opponent.
	FinisherDelta: number,
	-- Rating change for each opponent, keyed by UserId.
	OpponentDeltas: { [number]: number },
	-- The best per-opponent weight seen. MatchService uses it to decide what
	-- the race is worth for points and streak: beating one familiar rival
	-- alongside three fresh opponents is still a real win.
	BestWeight: number,
}

-- Settles ONE finisher against everyone still out on the course.
--
-- Called each time somebody crosses the line, which is what makes placement
-- matter: a race of N is the N(N-1)/2 pairwise results it actually contains.
-- When you finish you have beaten exactly the people still racing, and you were
-- already beaten by everyone who crossed before you -- settled when THEY
-- finished. Every pair resolves once, in order, with no need to wait for the
-- race to end.
--
-- K is divided by (N-1) so a big race isn't worth more total rating than a
-- small one: the winner of an 8-player race settles 7 pairs, and without this
-- their swing would be seven times a duel's.
function RaceSettlement.SettleFinisher(
	finisher: Racer,
	behind: { Opponent },
	totalParticipants: number,
	kFactor: number
): Result
	local pairShare = 1 / math.max(1, totalParticipants - 1)
	local finisherRating = finisher.Rating

	local result: Result = {
		FinisherDelta = 0,
		OpponentDeltas = {},
		BestWeight = 0,
	}

	for _, opponent in behind do
		-- Both damping factors multiply: a repeat opponent AND a fresh account
		-- is worth less than either alone.
		local resultWeight = opponent.RematchWeight * opponent.AgeWeight
		result.BestWeight = math.max(result.BestWeight, resultWeight)

		local winnerWeight = resultWeight * pairShare
		-- The loser's side is damped only by how established the WINNER is --
		-- never by the rematch count, which is the winner's own history and
		-- says nothing about how much rating the loser should shed.
		local loserWeight = finisher.AgeWeight * pairShare

		local winnerDelta, loserDelta = EloCalculator.CalculateDeltas(
			finisherRating,
			opponent.Rating,
			kFactor * math.clamp(winnerWeight, 0, 1),
			kFactor * math.clamp(loserWeight, 0, 1)
		)

		-- Rounded per pair, and the finisher's rating carries forward between
		-- them, matching how each pair used to be written to the profile as it
		-- resolved rather than batched. Without this the totals drift from what
		-- players actually see on their profile.
		local newFinisherRating = math.round(finisherRating + winnerDelta)
		local newOpponentRating = math.round(math.max(0, opponent.Rating + loserDelta))

		result.FinisherDelta += newFinisherRating - finisherRating
		result.OpponentDeltas[opponent.UserId] = newOpponentRating - opponent.Rating
		finisherRating = newFinisherRating
	end

	return result
end

-- Streak level N (2 wins in a row = level 1) is worth STREAK_BONUS_PER_LEVEL
-- extra points, capped at STREAK_BONUS_MAX_LEVEL so it stays a fun escalation
-- instead of spiralling.
local STREAK_BONUS_PER_LEVEL = 10
local STREAK_BONUS_MAX_LEVEL = 5

function RaceSettlement.StreakBonusPoints(winStreak: number): number
	local level = math.clamp(winStreak - 1, 0, STREAK_BONUS_MAX_LEVEL)
	return level * STREAK_BONUS_PER_LEVEL
end

export type WinReward = {
	-- Whether this win counts for progression at all. A fully damped win (the
	-- 9th+ over the same person inside the rematch window) pays nothing and
	-- counts for nothing -- no Wins, no streak. Anything above zero still
	-- counts; only the points scale. Otherwise the streak, which is the
	-- loudest farmable thing in the game now that it broadcasts server-wide,
	-- would keep climbing on wins the system has already judged worthless.
	CountsAsWin: boolean,
	-- The streak AFTER this race, which is what the points are computed from
	-- and what any announcement should quote.
	WinStreak: number,
	StreakBonus: number,
	Points: number,
}

-- What a win is worth: whether it counts, the resulting streak, and the points.
--
-- Pure for the same reason SettleFinisher is -- the interesting cases are all
-- about the interaction between streak, VIP multiplier and rematch damping, and
-- reproducing those by hand needs a player to win the same race nine times.
function RaceSettlement.WinReward(
	currentStreak: number,
	raceWeight: number,
	pointsPerWin: number,
	multiplier: number
): WinReward
	local countsAsWin = raceWeight > 0
	local winStreak = if countsAsWin then currentStreak + 1 else currentStreak
	local streakBonus = RaceSettlement.StreakBonusPoints(winStreak)

	return {
		CountsAsWin = countsAsWin,
		WinStreak = winStreak,
		StreakBonus = streakBonus,
		-- Floored, not rounded, so the payout can never exceed what the
		-- multiplier and weight actually justify.
		Points = math.floor((pointsPerWin + streakBonus) * multiplier * raceWeight),
	}
end

return RaceSettlement
