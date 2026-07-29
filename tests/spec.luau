--!nolint
-- Pure-logic tests for the shared rating/progression modules.
--
-- These exist because the rules they cover need N real Player instances to
-- exercise in game, and Player isn't a creatable class -- the only way to get
-- four is Studio's multi-client mode, one manual run at a time. The logic is
-- pure, so it can be checked here for any field size in milliseconds.
--
-- Run with tests/run.sh. Anything needing Players/Workspace/remotes does NOT
-- belong here -- test that in a Studio session.

-- Roblox datatypes (RankTiers stores a Color3 per tier) are stubbed by run.sh
-- as it copies the modules -- see the STUB block there. They can't be stubbed
-- from here, since _G is readonly in the Luau CLI sandbox.

local EloCalculator = require("./EloCalculator")
local RaceSettlement = require("./RaceSettlement")
local RankTiers = require("./RankTiers")
local Constants = require("./Constants")
local Hype = require("./Hype")

local pass, fail = 0, 0
local failures = {}

local function check(name: string, cond: boolean, detail: string?)
	if cond then
		pass += 1
	else
		fail += 1
		table.insert(failures, name .. (if detail then "  -- " .. detail else ""))
	end
	print(("%s  %s%s"):format(if cond then "ok  " else "FAIL", name, if detail then "  (" .. detail .. ")" else ""))
end

local START = Constants.Elo.StartingRating
local K = Constants.Elo.KFactor
local PPW = Constants.Match.PointsPerWin

print("\n-- rating scale and tiers --")
check("start is clear of the 0 floor", START > 0, ("start=%d"):format(START))
check("start is Bronze", RankTiers.GetRankForElo(START) == "Bronze", RankTiers.GetRankForElo(START))
check("Iron is the bottom tier", RankTiers.Tiers[1].Name == "Iron" and RankTiers.Tiers[1].MinElo == 0)
do
	local ascending, prev = true, -1
	for _, t in RankTiers.Tiers do
		if t.MinElo <= prev then
			ascending = false
		end
		prev = t.MinElo
	end
	check("tiers strictly ascending", ascending)
end
for elo, expected in { [799] = "Iron", [800] = "Bronze", [1199] = "Bronze", [1200] = "Silver", [3000] = "Grandmaster" } do
	check(("%d -> %s"):format(elo, expected), RankTiers.GetRankForElo(elo) == expected, RankTiers.GetRankForElo(elo))
end

print("\n-- elo calculator --")
do
	local w, l = EloCalculator.CalculateDeltas(1000, 1000, K, K)
	check("even match is zero-sum", math.abs(w + l) < 1e-9, ("%+.2f / %+.2f"):format(w, l))
	local _, nl = EloCalculator.CalculateNewRatings(1000, 5, K)
	check("loser never goes below 0", nl >= 0, ("loser -> %d"):format(nl))
	local zero = select(1, EloCalculator.CalculateDeltas(1000, 1000, 0, K))
	check("zero winner-K yields no gain", math.abs(zero) < 1e-9)
end

-- Drives a whole race through the shipped settlement, in finishing order,
-- exactly as MatchService does: each finisher settles against those still out.
local function race(n: number, ageWeights: { number }?, rematch: number?)
	local rating, delta = {}, {}
	for i = 1, n do
		rating[i] = START
		delta[i] = 0
	end
	for place = 1, n do
		local behind = {}
		for j = place + 1, n do
			table.insert(behind, {
				UserId = j,
				Rating = rating[j],
				AgeWeight = if ageWeights then ageWeights[j] else 1,
				RematchWeight = rematch or 1,
			})
		end
		local result = RaceSettlement.SettleFinisher({
			UserId = place,
			Rating = rating[place],
			AgeWeight = if ageWeights then ageWeights[place] else 1,
		}, behind, n, K)
		rating[place] += result.FinisherDelta
		delta[place] += result.FinisherDelta
		for id, d in result.OpponentDeltas do
			rating[id] += d
			delta[id] += d
		end
	end
	local sum = 0
	for i = 1, n do
		sum += delta[i]
	end
	return delta, sum
end

print("\n-- placement settlement --")
for _, n in { 2, 3, 4, 8, 20 } do
	local d, sum = race(n)
	local monotonic = true
	for i = 1, n - 1 do
		if d[i] <= d[i + 1] then
			monotonic = false
		end
	end
	check(("%d players: finishing order is strictly rewarded"):format(n), monotonic, table.concat(d, ", "))
	-- Rounding per pair means the total can land a point or two off zero; what
	-- matters is that a race doesn't mint or destroy meaningful rating.
	check(("%d players: sums to ~zero"):format(n), math.abs(sum) <= 2, ("sum=%+d"):format(sum))
end
do
	local d2 = race(2)
	local d8 = race(8)
	check("big races aren't worth more than small ones", math.abs(d2[1] - d8[1]) <= 3,
		("duel %+d vs 8-player %+d"):format(d2[1], d8[1]))
end

print("\n-- anti-farm --")
do
	local d = race(4, { 1, 0, 0, 0 })
	check("day-0 alts pay the winner nothing", d[1] == 0, ("winner %+d"):format(d[1]))
	local spent = race(2, nil, 0)
	check("spent rematch weight pays nothing", spent[1] == 0, ("winner %+d"):format(spent[1]))
	local partial = race(2, nil, 0.5)
	check("partial rematch weight pays less", partial[1] > 0 and partial[1] < 16, ("winner %+d"):format(partial[1]))
end

print("\n-- win rewards --")
check("streak 1 has no bonus", RaceSettlement.StreakBonusPoints(1) == 0)
check("streak 2 -> +10", RaceSettlement.StreakBonusPoints(2) == 10)
check("streak bonus caps at 50", RaceSettlement.StreakBonusPoints(6) == 50 and RaceSettlement.StreakBonusPoints(50) == 50)
do
	local first = RaceSettlement.WinReward(0, 1, PPW, 1)
	check("first win counts and pays PointsPerWin", first.CountsAsWin and first.WinStreak == 1 and first.Points == PPW,
		("%d pts"):format(first.Points))
	local streaked = RaceSettlement.WinReward(4, 1, PPW, 1)
	check("streak adds its bonus", streaked.Points == PPW + 40, ("%d pts"):format(streaked.Points))
	local vip = RaceSettlement.WinReward(0, 1, PPW, 2)
	check("VIP multiplier doubles", vip.Points == PPW * 2, ("%d pts"):format(vip.Points))

	local damped = RaceSettlement.WinReward(7, 0, PPW, 1)
	check("fully damped win doesn't count", not damped.CountsAsWin)
	check("fully damped win pays nothing", damped.Points == 0)
	check("fully damped win freezes the streak", damped.WinStreak == 7, ("streak %d"):format(damped.WinStreak))

	local half = RaceSettlement.WinReward(0, 0.5, PPW, 1)
	check("half weight still counts as a win", half.CountsAsWin)
	check("half weight halves the points", half.Points == math.floor(PPW * 0.5), ("%d pts"):format(half.Points))

	-- Ceiling is the full-weight payout for the streak this win PRODUCES (the
	-- streak increments first, so it's bonus(current + 1), not bonus(current)).
	local ceiling = PPW + RaceSettlement.StreakBonusPoints(4)
	local bounded, worst = true, 0
	for i = 0, 20 do
		local r = RaceSettlement.WinReward(3, i / 20, PPW, 1)
		worst = math.max(worst, r.Points)
		if r.Points < 0 or r.Points > ceiling then
			bounded = false
		end
	end
	check("points stay bounded across every weight", bounded, ("max %d of %d"):format(worst, ceiling))
	check("weight scales points monotonically",
		RaceSettlement.WinReward(3, 0.25, PPW, 1).Points < RaceSettlement.WinReward(3, 0.75, PPW, 1).Points)
end

print("\n-- hype milestones --")
do
	local ok, bad = true, {}
	for n = 1, 60 do
		local expected = n == 3 or n == 5 or (n >= 10 and n % 5 == 0)
		if Hype.ShouldAnnounceStreak(n) ~= expected then
			ok = false
			table.insert(bad, n)
		end
	end
	check("announces at 3, 5, 10 then every 5", ok, if #bad > 0 then "mismatch at " .. table.concat(bad, ", ") else nil)
end

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
	for _, name in failures do
		print("  FAILED: " .. name)
	end
	os.exit(1)
end
