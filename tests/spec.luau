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
local Stages = require("./Stages")
local StageLayout = require("./StageLayout")
local LayoutMath = require("./LayoutMath")
local Abilities = require("./Abilities")
local Weather = require("./Weather")
local ProfileSchema = require("./ProfileSchema")

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
	check(
		"big races aren't worth more than small ones",
		math.abs(d2[1] - d8[1]) <= 3,
		("duel %+d vs 8-player %+d"):format(d2[1], d8[1])
	)
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
check(
	"streak bonus caps at 50",
	RaceSettlement.StreakBonusPoints(6) == 50 and RaceSettlement.StreakBonusPoints(50) == 50
)
do
	local first = RaceSettlement.WinReward(0, 1, PPW, 1)
	check(
		"first win counts and pays PointsPerWin",
		first.CountsAsWin and first.WinStreak == 1 and first.Points == PPW,
		("%d pts"):format(first.Points)
	)
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
	check(
		"weight scales points monotonically",
		RaceSettlement.WinReward(3, 0.25, PPW, 1).Points < RaceSettlement.WinReward(3, 0.75, PPW, 1).Points
	)
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

print("\n-- stage roster --")
do
	local seenId, seenName, seenPair = {}, {}, {}
	local idsUnique, namesUnique, pairsUnique = true, true, true
	local difficultiesValid, gimmicksValid, weathersPresetted = true, true, true
	local validDifficulty = { Easy = true, Medium = true, Hard = true }
	local validGimmick = { Bounce = true, Moving = true, Vanishing = true, Speed = true }
	local counts = { Easy = 0, Medium = 0, Hard = 0 }

	for _, stage in Stages do
		if seenId[stage.Id] then
			idsUnique = false
		end
		if seenName[stage.Name] then
			namesUnique = false
		end
		seenId[stage.Id], seenName[stage.Name] = true, true

		-- A repeated weather+gimmick pair is two stages that play and look the
		-- same, which is the one thing more stages is supposed to fix.
		local pair = stage.Weather .. "+" .. stage.Gimmick
		if seenPair[pair] then
			pairsUnique = false
		end
		seenPair[pair] = true

		difficultiesValid = difficultiesValid and validDifficulty[stage.Difficulty] == true
		gimmicksValid = gimmicksValid and validGimmick[stage.Gimmick] == true
		-- A weather with no preset is a stage that races under whatever
		-- lighting the last stage left behind (Weather.GetForStage returns nil
		-- and WeatherService has nothing to apply).
		weathersPresetted = weathersPresetted and Weather.Presets[stage.Weather] ~= nil
		if validDifficulty[stage.Difficulty] then
			counts[stage.Difficulty] += 1
		end
	end

	check("stage ids unique", idsUnique)
	check("stage names unique", namesUnique)
	check("no weather+gimmick pair repeats", pairsUnique)
	check("every difficulty is a real tier", difficultiesValid)
	check("every gimmick is a real kind", gimmicksValid)
	check("every weather has a lighting preset", weathersPresetted)
	check(
		"every difficulty tier is represented",
		counts.Easy > 0 and counts.Medium > 0 and counts.Hard > 0,
		("%d easy / %d medium / %d hard"):format(counts.Easy, counts.Medium, counts.Hard)
	)
	-- A random roll should land on a punishing course less than half the time.
	check("hard stages are the minority", counts.Hard < #Stages / 2, ("%d of %d"):format(counts.Hard, #Stages))
end

print("\n-- jump reach --")
do
	local level = StageLayout.MaxJumpGap(0)
	-- Sprinting off a level edge at the shipped constants. This is the number
	-- every gap in every generated course is sized against, so if a tuning
	-- change moves it, the courses move with it.
	check("level sprint jump is ~12.2 studs", math.abs(level - 12.23) < 0.1, ("%.2f"):format(level))
	check("climbing costs reach", StageLayout.MaxJumpGap(3) < level, ("%.2f"):format(StageLayout.MaxJumpGap(3)))
	check("dropping adds reach", StageLayout.MaxJumpGap(-3) > level, ("%.2f"):format(StageLayout.MaxJumpGap(-3)))
	check("unreachable height yields no gap", StageLayout.MaxJumpGap(50) == 0)
	local monotonic = true
	for rise = -6, 6 do
		if StageLayout.MaxJumpGap(rise) >= StageLayout.MaxJumpGap(rise - 1) then
			monotonic = false
		end
	end
	check("reach falls off monotonically with climb", monotonic)
end

-- Every generated course, checked the way a player would fail it: can each
-- jump actually be made, do the platforms the bots follow exist in order, and
-- does the starting field fit on the pad. These are the failures that need a
-- Studio session and a stopwatch to find otherwise -- and an unclearable gap
-- is a stage nobody can ever finish.
print("\n-- generated courses --")
for _, stage in Stages do
	if not stage.Generated then
		continue
	end

	local plan = StageLayout.Build(stage)
	local platforms = plan.Platforms
	local label = stage.Id .. " (" .. stage.Difficulty .. "/" .. stage.Gimmick .. ")"

	do
		-- BotService walks Platform_Start, then counts up from Platform_1
		-- until one is MISSING, then Platform_Finish. A hole in the numbering
		-- silently truncates the bots' route at the hole.
		local named = platforms[1].Name == "Platform_Start" and platforms[#platforms].Name == "Platform_Finish"
		for i = 2, #platforms - 1 do
			named = named and platforms[i].Name == "Platform_" .. tostring(i - 1)
		end
		check(label .. ": platform chain is contiguous", named, ("%d platforms"):format(#platforms))
	end

	do
		-- StageGimmickService sorts platforms by position along the course's
		-- dominant axis and assumes that order IS the running order, so any
		-- backtracking in X would scramble which platforms get the gimmick.
		local increasing = true
		for i = 2, #platforms do
			if platforms[i].X <= platforms[i - 1].X then
				increasing = false
			end
		end
		check(label .. ": runs monotonically down the course", increasing)
	end

	do
		local worstMargin, worstAt = math.huge, 0
		local clearance, overlapAt = true, 0
		for i = 2, #platforms do
			local previous, current = platforms[i - 1], platforms[i]
			local forward = (current.X - current.SizeX / 2) - (previous.X + previous.SizeX / 2)
			local lateral = current.Z - previous.Z
			local rise = current.Y - previous.Y
			-- The jump is the straight line between the two edges, not the
			-- forward component alone.
			local distance = math.sqrt(forward * forward + lateral * lateral)
			local reach = StageLayout.MaxJumpGap(rise)
			local margin = if reach > 0 then (reach - distance) / reach else -1
			if margin < worstMargin then
				worstMargin, worstAt = margin, i
			end
			if forward < 3 - 1e-9 then
				clearance, overlapAt = false, i
			end
		end
		-- 15%, against StageLayout's own 20% design margin: a player arrives
		-- at a takeoff edge with whatever speed they have, not always a clean
		-- sprint.
		check(
			label .. ": every jump clearable with margin",
			worstMargin > 0.15,
			("worst %.0f%% spare at platform %d"):format(worstMargin * 100, worstAt)
		)
		check(
			label .. ": platforms never touch",
			clearance,
			if overlapAt > 0 then ("overlap at platform %d"):format(overlapAt) else nil
		)
	end

	do
		-- Checkpoints must sit on the platforms StageGimmickService does NOT
		-- animate (it takes list indices 2, 4, 6...), or a save point ends up
		-- on a platform that fades out and drops away.
		local onStillPlatforms, onTop = #plan.Checkpoints > 0, true
		for _, checkpoint in plan.Checkpoints do
			local host = nil
			for index, platform in platforms do
				if math.abs(platform.X - checkpoint.X) < 1e-6 then
					host = index
					-- Sitting ON the platform, not floating over it or sunk in
					-- it: this CFrame is where a fall puts the player back.
					onTop = onTop
						and math.abs(checkpoint.Y - checkpoint.SizeY / 2 - (platform.Y + platform.SizeY / 2)) < 1e-6
				end
			end
			if not host or host % 2 == 0 or host == 1 or host == #platforms then
				onStillPlatforms = false
			end
		end
		check(
			label .. ": checkpoints avoid gimmick platforms",
			onStillPlatforms,
			("%d checkpoints"):format(#plan.Checkpoints)
		)
		check(label .. ": checkpoints sit on the deck", onTop)
	end

	do
		local finishPad = platforms[#platforms]
		local banner = plan.Finish
		-- Across the pad's near edge and tall enough that an arc can't clear
		-- it: this part is what win detection is bound to.
		check(
			label .. ": finish banner crosses the pad",
			banner.SizeZ > finishPad.SizeZ * 0.9 and banner.SizeY >= 12,
			("%.1f wide, %.1f tall"):format(banner.SizeZ, banner.SizeY)
		)
		check(
			label .. ": finish banner stands on the pad",
			banner.Y - banner.SizeY / 2 >= finishPad.Y + finishPad.SizeY / 2 - 1e-6
		)
	end

	do
		local lowest = math.huge
		local minX, maxX = math.huge, -math.huge
		for _, platform in platforms do
			lowest = math.min(lowest, platform.Y - platform.SizeY / 2)
			minX = math.min(minX, platform.X - platform.SizeX / 2)
			maxX = math.max(maxX, platform.X + platform.SizeX / 2)
		end
		local void = plan.Void
		check(label .. ": void hangs below the course", void.Y + void.SizeY / 2 < lowest)
		-- Wider than the course on both sides, and generous past the finish:
		-- overshooting the finish is a real outcome on a Speed stage.
		check(
			label .. ": void covers the whole footprint",
			void.X - void.SizeX / 2 < minX and void.X + void.SizeX / 2 > maxX + 40
		)
	end

	do
		-- Replays MatchService.buildStartGrid against the pad this plan
		-- actually produces, for a field far bigger than the queue usually
		-- sends (there is no player cap), and asserts nobody is spawned off
		-- the edge -- the bug the grid was written to fix.
		local startPad = platforms[1]
		local spawn = plan.Spawn
		local SPACING, MARGIN = 5, 3
		local fits = true
		local worst = 0
		-- The grid's own axes: columns spread ACROSS the course (the pad's Z
		-- side), rows build backwards ALONG it (the pad's X side). The spawn
		-- marker is rotated to face down the course, which is why its local
		-- sizes are the other way round -- see buildSpawn.
		local acrossHalf = startPad.SizeZ / 2
		local alongHalf = startPad.SizeX / 2
		for _, count in { 8, 16, 24 } do
			local usableX = math.max(0, spawn.SizeX - MARGIN * 2)
			local usableZ = math.max(0, spawn.SizeZ / 2 - MARGIN)
			local columns = math.clamp(math.floor(usableX / SPACING) + 1, 1, count)
			local rows = math.ceil(count / columns)
			local spacingX = if columns > 1 then math.min(SPACING, usableX / (columns - 1)) else 0
			local spacingZ = if rows > 1 then math.min(SPACING, usableZ / (rows - 1)) else 0
			for index = 1, count do
				local slot = index - 1
				local column = slot % columns
				local row = math.floor(slot / columns)
				local inThisRow = math.min(columns, count - row * columns)
				local offsetX = (column - (inThisRow - 1) / 2) * spacingX
				local offsetZ = row * spacingZ
				worst = math.max(worst, math.abs(offsetX) / acrossHalf, offsetZ / alongHalf)
				if math.abs(offsetX) > acrossHalf - 1.5 or offsetZ > alongHalf - 1.5 then
					fits = false
				end
			end
		end
		check(label .. ": start grid stays on the pad", fits, ("worst slot at %.0f%% of the pad"):format(worst * 100))
		check(
			label .. ": spawn marker is most of the pad",
			spawn.SizeX > startPad.SizeZ * 0.8 and spawn.SizeZ > startPad.SizeX * 0.8
		)
	end
end

-- StageEndpointService sizes the hand-built stages' spawn markers with this
-- same rule, off pads it measures in Studio rather than the ones planned here,
-- so it has to cope with a marker that has less pad behind it than a centred
-- one would -- the case where a full-size marker lays the back row of the grid
-- out into thin air.
print("\n-- spawn marker sizing --")
do
	local PAD_ACROSS, PAD_ALONG = 28, 30

	local across, along = StageLayout.SpawnMarkerSize(PAD_ACROSS, PAD_ALONG, PAD_ALONG / 2)
	check(
		"centred marker uses the inset pad size",
		across == PAD_ACROSS * 0.9 and along == PAD_ALONG * 0.9,
		("%.1f across, %.1f along"):format(across, along)
	)

	local _, shallowAlong = StageLayout.SpawnMarkerSize(PAD_ACROSS, PAD_ALONG, 4)
	check("marker near the back edge shrinks to fit", shallowAlong == 8, ("%.1f along"):format(shallowAlong))

	local _, noneAlong = StageLayout.SpawnMarkerSize(PAD_ACROSS, PAD_ALONG, 0)
	check("marker on the back edge leaves no depth", noneAlong == 0)

	local _, negativeAlong = StageLayout.SpawnMarkerSize(PAD_ACROSS, PAD_ALONG, -6)
	check("marker off the back of the pad clamps, not inverts", negativeAlong == 0)

	-- Rows are laid out over HALF the local Z size, so the grid can only stay
	-- on the pad if that half never exceeds the depth actually behind it.
	local staysOnPad = true
	for depth = 0, 15 do
		local _, sized = StageLayout.SpawnMarkerSize(PAD_ACROSS, PAD_ALONG, depth)
		if sized / 2 > depth + 1e-9 then
			staysOnPad = false
		end
	end
	check("grid depth never exceeds the pad behind the marker", staysOnPad)
end

-- Growing those pads left them hanging off the void slab authored under them,
-- so StageEndpointService now unions the slab's span with the pads' on each of
-- the slab's own axes. The union is the part that can silently go wrong -- it
-- must never hand back a span smaller than the one it was given, or a stage
-- loses trigger coverage it had before this ran.
-- The HUD's responsive geometry. These functions decide the size and position
-- of every panel in twenty-odd controllers, and the bugs they exist to fix were
-- all of the same shape: something resolved to a coordinate off the edge of a
-- phone, and nobody noticed because the developer monitor is 1280 wide.
--
-- The reference viewports below are the ones that matter: a desktop at exactly
-- REFERENCE_WIDTH (where every number must come out unchanged, since this whole
-- approach is meant to be a widening rather than a redesign), and an
-- iPhone-class landscape phone, which is where everything broke.
print("\n-- responsive layout math --")
do
	local DESKTOP = { Width = 1280, Height = 720, Touch = false }
	local PHONE = { Width = 667, Height = 375, Touch = true }
	local TINY = { Width = 400, Height = 300, Touch = true }
	local ULTRAWIDE = { Width = 3840, Height = 2160, Touch = false }

	-- The single most important property here: the reference desktop must be a
	-- no-op. If this fails, the retrofit changed what desktop players see.
	check("reference viewport scales by exactly 1", LayoutMath.Scale(DESKTOP) == 1)
	local identity = true
	for _, offset in { 1, 8, 16, 44, 104, 264, 300, 480, 528 } do
		if LayoutMath.Px(DESKTOP, offset) ~= offset then
			identity = false
		end
	end
	check("every authored offset is unchanged on the reference viewport", identity)
	check("text is unchanged on the reference viewport", LayoutMath.Text(DESKTOP, 24) == 24)

	check("a phone scales down", LayoutMath.Scale(PHONE) < 1, ("%.3f"):format(LayoutMath.Scale(PHONE)))
	check("the scale floor holds", LayoutMath.Scale(TINY) == LayoutMath.MinScale)
	check("the scale ceiling holds", LayoutMath.Scale(ULTRAWIDE) == LayoutMath.MaxScale)
	-- Chrome growing with the screen is the mistake in the other direction, so
	-- the ceiling has to be a real limit rather than a large number.
	check("a 4K monitor does not get a 3x HUD", LayoutMath.Px(ULTRAWIDE, 100) <= 115)

	check("offsets are whole pixels", LayoutMath.Px(PHONE, 37) % 1 == 0)
	check("text never drops below the legible floor", LayoutMath.Text(TINY, 4) == LayoutMath.MinTextSize)

	-- Tap() is the one that protects fingers: scaling a 44pt button down on the
	-- very device that uses a thumb is precisely backwards.
	check(
		"a tap target never shrinks below the touch minimum",
		LayoutMath.Tap(PHONE, 26) == LayoutMath.MinTouchTarget,
		("%d"):format(LayoutMath.Tap(PHONE, 26))
	)
	check("a large tap target still scales", LayoutMath.Tap(PHONE, 200) < 200)
	check("desktop tap targets are not inflated", LayoutMath.Tap(DESKTOP, 26) == 26)
	local everyTargetIsReachable = true
	-- The real sizes that were flagged in the audit, worst first.
	for _, size in { 26, 32, 36, 40, 44, 48 } do
		if LayoutMath.Tap(PHONE, size) < LayoutMath.MinTouchTarget then
			everyTargetIsReachable = false
		end
	end
	check("every audited button size clears the touch minimum on a phone", everyTargetIsReachable)

	check("tiers read off width", LayoutMath.Tier(PHONE) == "Phone" and LayoutMath.Tier(DESKTOP) == "Desktop")
	check("the touch band is touch-only", LayoutMath.TouchBand(PHONE) > 0 and LayoutMath.TouchBand(DESKTOP) == 0)

	-- Workspace.CurrentCamera.ViewportSize really does report (1, 1) for a
	-- 1001x747 window, and it does not necessarily correct itself. A width of 1
	-- clamps straight to MinScale, so the entire desktop HUD renders at phone
	-- size with nothing thrown and nothing in the log -- which is exactly what
	-- happened, and was only caught by measuring a running client. Responsive
	-- rejects a reading this small and falls back; these are the cases it has to
	-- reject.
	check("a 1x1 viewport is rejected", not LayoutMath.IsSaneViewport(1, 1))
	check("a zero viewport is rejected", not LayoutMath.IsSaneViewport(0, 0))
	check("a real phone is accepted", LayoutMath.IsSaneViewport(PHONE.Width, PHONE.Height))
	check("a small desktop window is accepted", LayoutMath.IsSaneViewport(640, 480))
	-- The floor must sit below any device and above any bad read.
	check(
		"the sanity floor is below every real device",
		LayoutMath.MinSaneViewport < 320,
		("%d"):format(LayoutMath.MinSaneViewport)
	)

	-- Both of these come from measuring the actual device emulator, which
	-- reported 801x334 -- not from reasoning about what a phone "should" be.
	local EMULATED_PHONE = { Width = 801, Height = 334, Touch = true }

	-- 801 is one point over the old width-only phone threshold, so a real phone
	-- was being classified as a Tablet and none of the phone reflows fired.
	check(
		"the emulated phone is classified as a Phone",
		LayoutMath.Tier(EMULATED_PHONE) == "Phone",
		LayoutMath.Tier(EMULATED_PHONE)
	)
	check(
		"a landscape tablet is still a Tablet",
		LayoutMath.Tier({ Width = 1180, Height = 700, Touch = true }) == "Tablet"
	)
	-- A narrow desktop WINDOW is not a phone -- no touch, so width still rules.
	check(
		"a short desktop window is not a phone",
		LayoutMath.Tier({ Width = 1600, Height = 400, Touch = false }) == "Desktop"
	)

	-- The flat 190pt band is 57% of a 334-tall screen, which left FitHeight
	-- almost nothing to work with.
	local band = LayoutMath.TouchBand(EMULATED_PHONE)
	check(
		"the control band never eats half a short screen",
		band < EMULATED_PHONE.Height * 0.5,
		("%d of %d"):format(band, EMULATED_PHONE.Height)
	)
	-- Calibrated against the real control, not a guess: Roblox's jump button
	-- measured 70x70 with its top edge 90pt above the bottom of the screen, so
	-- the band has to cover at least the button plus a little margin. An earlier
	-- version of this test asserted >= 100 purely because that was the number the
	-- code happened to produce.
	check("the band covers the real jump button", band >= 80, ("%d, button needs ~90"):format(band))
	check("the band is exactly the documented value", band == 90, ("%d"):format(band))
	-- Roblox's documented jump-button geometry: 70x70 below a 500pt minimum axis
	-- sitting size+20 off the bottom, 120x120 above it sitting size*1.75 off. The
	-- old share-of-height guess UNDER-reserved a tablet (162 against a real 210)
	-- while over-reserving a phone's corners (190 against a real 105).
	local tablet = { Width = 1180, Height = 800, Touch = true }
	check(
		"a large touch screen reserves the documented 210",
		LayoutMath.TouchBand(tablet) == 210,
		("%d"):format(LayoutMath.TouchBand(tablet))
	)
	check(
		"phone corners are the documented 105",
		LayoutMath.CornerWidth(EMULATED_PHONE) == 105,
		("%d"):format(LayoutMath.CornerWidth(EMULATED_PHONE))
	)
	check(
		"tablet corners are the documented 180",
		LayoutMath.CornerWidth(tablet) == 180,
		("%d"):format(LayoutMath.CornerWidth(tablet))
	)

	-- The correction that reclaimed a third of the phone screen: the controls do
	-- not own a full-width band, so a row narrow enough to pass through the clear
	-- strip reaches the real bottom instead of being stranded above one.
	local narrow = LayoutMath.BottomRowY(EMULATED_PHONE, 0, 44, 300)
	local wide = LayoutMath.BottomRowY(EMULATED_PHONE, 0, 44, 780)
	check(
		"a row fitting between the controls reaches the bottom",
		narrow > wide,
		("narrow y=%d vs wide y=%d"):format(narrow, wide)
	)
	check(
		"a bottom row still respects the screen margin",
		narrow + 44 <= EMULATED_PHONE.Height - LayoutMath.ScreenMargin + 1,
		("ends at %d of %d"):format(narrow + 44, EMULATED_PHONE.Height)
	)
	check(
		"there is real room left for chrome on the emulated phone",
		EMULATED_PHONE.Height - band - LayoutMath.ScreenMargin * 2 > 150,
		("%d usable"):format(EMULATED_PHONE.Height - band - LayoutMath.ScreenMargin * 2)
	)
end

-- The clamps are what actually stopped panels being drawn off the screen, so
-- they get their own section: every one of these corresponds to a real panel
-- that was partly or wholly invisible on a phone.
print("\n-- responsive clamping --")
do
	local PHONE = { Width = 667, Height = 375, Touch = true }
	local DESKTOP = { Width = 1280, Height = 720, Touch = false }
	local margin = LayoutMath.ScreenMargin

	-- The six real overflows, by reference height, as measured in the audit.
	local PANELS = {
		{ Name = "Gacha", Height = 520, Top = 116 },
		{ Name = "Tutorial", Height = 528, Top = 8 },
		{ Name = "Inventory", Height = 480, Top = 8 },
		{ Name = "Shop", Height = 460, Top = 116 },
		{ Name = "Leaderboard", Height = 454, Top = 116 },
		{ Name = "RaceOutcome", Height = 196, Top = 206 },
	}
	local allFit = true
	local worst = ""
	for _, panel in PANELS do
		local height = LayoutMath.FitHeight(PHONE, panel.Height, margin)
		local y = LayoutMath.ClampY(PHONE, panel.Top, height)
		if y + height > PHONE.Height - margin + 1e-9 or y < margin - 1e-9 then
			allFit = false
			worst = panel.Name
		end
	end
	check("every panel that overflowed now fits a phone", allFit, if allFit then "6 panels" else worst)

	-- A panel is positioned from its top, so a clamp that let the top go
	-- negative would trade a lost footer for a lost header -- which is exactly
	-- what the tutorial did (title off the top, dismiss button off the bottom).
	check("clamping never pushes a top edge off-screen", LayoutMath.ClampY(PHONE, -400, 200) >= margin)
	check("clamping never pushes a left edge off-screen", LayoutMath.ClampX(PHONE, -400, 200) >= margin)
	check("a box taller than the screen still starts on-screen", LayoutMath.ClampY(PHONE, 100, 10000) >= margin)

	check(
		"desktop panels are untouched by FitHeight",
		LayoutMath.FitHeight(DESKTOP, 520, 116) == 520,
		("%d"):format(LayoutMath.FitHeight(DESKTOP, 520, 116))
	)

	-- ClearCorners keeps low-sitting controls out of the movement pad and the
	-- jump button. Both keep-outs come from the real control geometry rather than
	-- flat constants, so both depend on the viewport -- and they are ASYMMETRIC:
	-- the pad claims the left 40% of the width, the jump button only 1.5 button
	-- widths of the right.
	local corner = LayoutMath.CornerWidth(PHONE)
	local pad = LayoutMath.MoveAreaWidth(PHONE)
	check("the movement pad is wider than the jump corner", pad > corner, ("pad %d vs corner %d"):format(pad, corner))
	check("a control over the movement pad is pushed clear", LayoutMath.ClearCorners(PHONE, 10, 145) >= pad)
	check(
		"a control in the right corner is pushed clear",
		LayoutMath.ClearCorners(PHONE, 600, 145) + 145 <= PHONE.Width - corner
	)
	-- Screen-centred is NOT clear on a phone: 260 is inside the pad, which is the
	-- bug that made SPRINT eat movement touches.
	check(
		"a screen-centred control is still pushed off the pad",
		LayoutMath.ClearCorners(PHONE, 260, 145) == pad,
		("x=%d vs pad %d"):format(LayoutMath.ClearCorners(PHONE, 260, 145), pad)
	)
	check("a control already in the clear strip is left alone", LayoutMath.ClearCorners(PHONE, pad + 5, 145) == pad + 5)
	check("desktop is never nudged", LayoutMath.ClearCorners(DESKTOP, 0, 145) == 0)

	-- A control wider than the clear strip can't escape both keep-outs. It must
	-- still come back centred ON THE SCREEN rather than jammed against one side,
	-- pushed to a negative coordinate by two fighting clamps, or (centred on the
	-- off-centre strip instead) shoved past the right edge of the display.
	local wide = LayoutMath.ClearCorners(PHONE, 0, 600)
	check(
		"an over-wide control centres instead of oscillating",
		math.abs(wide - (PHONE.Width - 600) / 2) < 1,
		("x=%d"):format(wide)
	)
	check("an over-wide control still fits on screen", wide >= 0 and wide + 600 <= PHONE.Width, ("x=%d"):format(wide))

	-- When a box CAN clear the movement pad and still fit on screen, it does --
	-- even though that leaves it overlapping the jump button. Measured on a
	-- 706x579 tablet, where SPRINT+DASH is 259 wide against a 244-wide strip:
	-- centring it on the screen put 58pt of SPRINT on the pad, which is what
	-- makes a sprint press eat the touch that would have started a walk.
	local TABLET_TOUCH = { Width = 706, Height = 579, Touch = true }
	local padEnd = LayoutMath.MoveAreaWidth(TABLET_TOUCH)
	local squeezed = LayoutMath.ClearCorners(TABLET_TOUCH, 224, 259)
	check(
		"a control too wide for the strip still clears the movement pad",
		squeezed >= padEnd,
		("x=%d, pad ends at %d"):format(squeezed, padEnd)
	)
	check(
		"and stays on screen while doing it",
		squeezed + 259 <= TABLET_TOUCH.Width,
		("ends at %d of %d"):format(squeezed + 259, TABLET_TOUCH.Width)
	)

	-- The whole point of the pad keep-out: the action row must not sit on top of
	-- the movement control, at any of the sizes a phone actually reports.
	for _, view in
		{
			{ Width = 801, Height = 334, Touch = true },
			{ Width = 667, Height = 375, Touch = true },
			{ Width = 960, Height = 450, Touch = true },
		}
	do
		local row = LayoutMath.ActionRow(view)
		local left, right = LayoutMath.ClearStrip(view)
		local last = row.Positions[#row.Positions] + row.Widths[#row.Widths]
		check(
			("the action row clears the movement pad at %dx%d"):format(view.Width, view.Height),
			row.Positions[1] >= left,
			("starts at %d, pad ends at %d"):format(row.Positions[1], left)
		)
		check(
			("the action row clears the jump button at %dx%d"):format(view.Width, view.Height),
			last <= right,
			("ends at %d, jump starts at %d"):format(last, right)
		)
		check(
			("the action row keeps its order at %dx%d"):format(view.Width, view.Height),
			row.Positions[1] < row.Positions[2] and row.Positions[2] < row.Positions[3]
		)
		check(
			("the action row keeps PLAY the widest at %dx%d"):format(view.Width, view.Height),
			row.Widths[2] > row.Widths[1] and row.Widths[2] > row.Widths[3],
			("%d / %d / %d"):format(row.Widths[1], row.Widths[2], row.Widths[3])
		)
		check(
			("the action row may sit at the very bottom at %dx%d"):format(view.Width, view.Height),
			LayoutMath.BottomRowY(view, 0, 44, row.Total) > LayoutMath.BottomRowY(view, 0, 44, view.Width)
		)
	end
end

print("\n-- profile schema --")
do
	-- The bug this guards: PlayerDataService used to build a profile with
	-- table.clone (a SHALLOW copy) and fill missing keys straight off the
	-- template, so every player in a server who needed a default shared ONE
	-- OwnedTrails array -- and one OwnedAbilities, OwnedEmotes and
	-- ProcessedPurchaseIds. One player's Robux purchase landed in everybody
	-- else's profile and in the template itself, then persisted to each of
	-- their DataStore keys. It needs two players to show up, which is why a
	-- one-client Studio test never found it.
	local TABLE_FIELDS = { "OwnedTrails", "OwnedAbilities", "OwnedEmotes", "AwardedBadgeKeys", "ProcessedPurchaseIds" }

	local alice = ProfileSchema.New(nil)
	local bob = ProfileSchema.New(nil)
	for _, field in TABLE_FIELDS do
		check(
			("two fresh profiles do not share %s"):format(field),
			alice[field] ~= bob[field] and alice[field] ~= ProfileSchema.Default[field]
		)
	end

	-- The actual consequence, end to end.
	table.insert(alice.OwnedTrails, "Galaxy")
	check("a purchase does not leak to another player", table.find(bob.OwnedTrails, "Galaxy") == nil)
	check("a purchase does not leak into the template", table.find(ProfileSchema.Default.OwnedTrails, "Galaxy") == nil)
	check("a purchase does not leak to a later joiner", table.find(ProfileSchema.New(nil).OwnedTrails, "Galaxy") == nil)

	alice.ProcessedPurchaseIds["guid-alice"] = true
	check("receipt ids stay per-player", bob.ProcessedPurchaseIds["guid-alice"] == nil)

	-- A returning save predating a field gets its own copy of that default too.
	local returning = ProfileSchema.New({ Elo = 1400, EloScaleVersion = 2, OwnedTrails = { "Basic", "Flame" } })
	check("a legacy save gets its own OwnedAbilities", returning.OwnedAbilities ~= ProfileSchema.Default.OwnedAbilities)
	table.insert(returning.OwnedAbilities, "Blink")
	check(
		"a gacha pull does not leak to a new player",
		table.find(ProfileSchema.New(nil).OwnedAbilities, "Blink") == nil
	)

	-- Existing data is never overwritten by the fill.
	check("existing fields survive the default fill", #returning.OwnedTrails == 2 and returning.Elo == 1400)

	-- Nested tables are copied too, not just the top level.
	local nested = ProfileSchema.New(nil)
	check("defaults are deep-copied", ProfileSchema.DeepCopy({ a = { b = 1 } }).a ~= nil)
	check("every default key is present", nested.EquippedTrail == "Basic" and nested.EquippedAbility == "Dash")

	-- Elo scale migration: a pre-v2 save is shifted onto the new floor exactly once.
	local legacy = ProfileSchema.New({ Elo = 300 })
	check(
		"a pre-v2 save is rebased onto the new scale",
		legacy.Elo == 300 + START and legacy.EloScaleVersion == ProfileSchema.EloScaleVersion,
		("elo=%d"):format(legacy.Elo)
	)
	local alreadyMigrated = ProfileSchema.New({ Elo = 300 + START, EloScaleVersion = ProfileSchema.EloScaleVersion })
	check("an already-migrated save is left alone", alreadyMigrated.Elo == 300 + START)
	-- A brand-new player starts on the new floor, not shifted twice.
	check("a new profile starts at the rating floor", ProfileSchema.New(nil).Elo == START)
end

print("\n-- void slab coverage --")
do
	local CURRENT_MIN, CURRENT_MAX = -50, 50

	local centre, size = StageLayout.CoverSpan(CURRENT_MIN, CURRENT_MAX, -10, 10)
	check(
		"a span already covering the pads is left alone",
		centre == 0 and size == 100,
		("centre %.1f, size %.1f"):format(centre, size)
	)

	-- The reported case: the pad overhangs one end by a couple of studs.
	local offCentre, offSize = StageLayout.CoverSpan(CURRENT_MIN, CURRENT_MAX, -52.5, 10)
	check(
		"an overhang extends only the end that overhangs",
		offSize == 102.5 and offCentre == -1.25,
		("centre %.2f, size %.2f"):format(offCentre, offSize)
	)

	local _, bothSize = StageLayout.CoverSpan(CURRENT_MIN, CURRENT_MAX, -60, 70)
	check("overhangs at both ends both extend", bothSize == 130, ("%.1f"):format(bothSize))

	-- The one that matters: a pad well inside the slab must not pull it in.
	local neverShrinks = true
	for half = 1, 60 do
		local _, sized = StageLayout.CoverSpan(CURRENT_MIN, CURRENT_MAX, -half, half)
		if sized < CURRENT_MAX - CURRENT_MIN - 1e-9 then
			neverShrinks = false
		end
	end
	check("covering never shrinks the slab", neverShrinks)

	-- The result has to actually contain both inputs, not just be big enough.
	local contains = true
	for _, span in { { -70, -60 }, { 60, 80 }, { -5, 5 }, { -80, 80 } } do
		local c, s = StageLayout.CoverSpan(CURRENT_MIN, CURRENT_MAX, span[1], span[2])
		if c - s / 2 > math.min(CURRENT_MIN, span[1]) + 1e-9 or c + s / 2 < math.max(CURRENT_MAX, span[2]) - 1e-9 then
			contains = false
		end
	end
	check("the covered span contains both inputs", contains)

	-- A pad entirely off one end (not overlapping at all) still has to be
	-- swallowed rather than producing a span that skips the gap between them.
	local disjointCentre, disjointSize = StageLayout.CoverSpan(CURRENT_MIN, CURRENT_MAX, 200, 220)
	check(
		"a disjoint pad is bridged, not jumped to",
		disjointSize == 270 and disjointCentre == 85,
		("centre %.1f, size %.1f"):format(disjointCentre, disjointSize)
	)

	check(
		"the pad margin clears a character's width",
		StageLayout.Void.PadMargin >= 2,
		("%.1f"):format(StageLayout.Void.PadMargin)
	)
end

-- StageEndpointService reshapes Stage1-4's start and finish pads to
-- StageLayout.Endpoint, and StageBuilderService builds Stage5-8's from
-- buildPlatforms. Those are two different code paths to "the eight stages start
-- and end the same way", so the numbers behind them have to be the same
-- numbers -- this is the assertion that they are, since nothing else compares
-- the hand-built half against the generated one.
-- StageService puts a capture volume this tall over every checkpoint's platform,
-- because touching the visible 0.3-stud pad was never a reliable test of having
-- reached a checkpoint -- a Meteor Dash arcs clean over it, and the player
-- silently loses their save point. So the volume has to be taller than anything
-- that can carry a racer across a checkpoint platform. These are the numbers
-- that decide that, and buffing any of them should fail here rather than quietly
-- make a checkpoint unreachable again.
print("\n-- checkpoint capture height --")
do
	local capture = StageLayout.Checkpoint.CaptureHeight
	local hip = StageLayout.Checkpoint.HipHeight

	local meteor
	for _, ability in Abilities do
		if ability.Id == "Meteor" then
			meteor = ability
		end
	end
	check(
		"Meteor Dash is still a lifting dash",
		meteor ~= nil and (meteor.UpwardBoost or 0) > 0,
		meteor and ("%d studs/s for %.2fs"):format(meteor.UpwardBoost, meteor.DurationSeconds)
	)

	local meteorPeak = hip + StageLayout.LaunchArcHeight(meteor.UpwardBoost, meteor.DurationSeconds)
	check(
		"capture volume clears a Meteor Dash",
		capture > meteorPeak,
		("peak %.1f vs volume %.1f"):format(meteorPeak, capture)
	)

	-- StageGimmickService's BOUNCE_UP / BOUNCE_THRUST. Duplicated here because
	-- they live in a server module the headless runner cannot require -- if they
	-- change, this is the line to update, and the check below is what makes the
	-- consequence of NOT updating it visible.
	local BOUNCE_UP, BOUNCE_THRUST = 55, 0.12
	local bouncePeak = hip + StageLayout.LaunchArcHeight(BOUNCE_UP, BOUNCE_THRUST)
	check(
		"capture volume clears a bounce pad",
		capture > bouncePeak,
		("peak %.1f vs volume %.1f"):format(bouncePeak, capture)
	)
	check(
		"bounce is the taller of the two, as documented",
		bouncePeak > meteorPeak,
		("bounce %.1f > meteor %.1f"):format(bouncePeak, meteorPeak)
	)

	-- The margin is the whole point: a dash fired while already rising off a
	-- bounce is not in either figure above.
	check(
		"volume keeps headroom over the worst single launch",
		capture - bouncePeak >= 5,
		("%.1f studs spare"):format(capture - bouncePeak)
	)

	check("a zero launch has no arc", StageLayout.LaunchArcHeight(0, 0.5) == 0)
	-- Held velocity and the ballistic arc off it, both accounted for: a helper
	-- that dropped either term would still look plausible at a glance.
	check(
		"arc counts the held climb and the ballistic rise",
		math.abs(StageLayout.LaunchArcHeight(50, 0.2) - (10 + 2500 / (2 * 196.2))) < 1e-9,
		("%.2f"):format(StageLayout.LaunchArcHeight(50, 0.2))
	)
end

print("\n-- endpoint convention --")
do
	local endpoint = StageLayout.Endpoint
	local generated
	for _, stage in Stages do
		if stage.Generated then
			generated = stage
			break
		end
	end
	local plan = StageLayout.Build(generated)
	local startPad = plan.Platforms[1]
	local finishPad = plan.Platforms[#plan.Platforms]

	check(
		"start pad matches the generated one",
		endpoint.StartPadAlong == startPad.SizeX and endpoint.StartPadAcross == startPad.SizeZ,
		("%.0f along, %.0f across"):format(endpoint.StartPadAlong, endpoint.StartPadAcross)
	)
	check(
		"finish pad matches the generated one",
		endpoint.FinishPadAlong == finishPad.SizeX and endpoint.FinishPadAcross == finishPad.SizeZ,
		("%.0f along, %.0f across"):format(endpoint.FinishPadAlong, endpoint.FinishPadAcross)
	)
	check("pad thickness matches the generated one", endpoint.PadThickness == finishPad.SizeY)

	-- The banner is rebuilt from these three off a pad measured in Studio, so a
	-- hand-built finish only ends up looking like a generated one if they
	-- reproduce plan.Finish exactly.
	check("banner height matches the generated one", endpoint.BannerHeight == plan.Finish.SizeY)
	check("banner thickness matches the generated one", endpoint.BannerThickness == plan.Finish.SizeX)
	check(
		"banner spans the same share of the pad",
		math.abs(endpoint.BannerWidthFactor * finishPad.SizeZ - plan.Finish.SizeZ) < 1e-9,
		("%.1f wide"):format(plan.Finish.SizeZ)
	)

	-- A start pad the field cannot fit on is the whole reason Stage1-4 needed
	-- reshaping rather than restyling, so the convention itself has to clear the
	-- bar a full wave sets.
	local across, along =
		StageLayout.SpawnMarkerSize(endpoint.StartPadAcross, endpoint.StartPadAlong, endpoint.StartPadAlong / 2)
	local MARGIN, SPACING, FIELD = 3, 5, 8
	local columns = math.clamp(math.floor(math.max(0, across - MARGIN * 2) / SPACING) + 1, 1, FIELD)
	check(
		"convention start pad holds a full wave",
		math.ceil(FIELD / columns) <= 2 and columns >= 4,
		("%d columns x %d rows on a %.0f x %.0f marker"):format(columns, math.ceil(FIELD / columns), across, along)
	)
end

do
	-- StageBuilderService stacks the generated courses in the sky on these
	-- numbers, so the extent has to cover the parts that reach FURTHEST -- the
	-- void slab below and the finish banner above, not just the decks.
	local coversHiddenParts, tallerThanDecks = true, true
	for _, stage in Stages do
		if stage.Generated then
			local plan = StageLayout.Build(stage)
			local extent = StageLayout.Extent(plan)
			local deckLow, deckHigh = math.huge, -math.huge
			for _, platform in plan.Platforms do
				deckLow = math.min(deckLow, platform.Y - platform.SizeY / 2)
				deckHigh = math.max(deckHigh, platform.Y + platform.SizeY / 2)
			end
			if extent.MinY > plan.Void.Y - plan.Void.SizeY / 2 then
				coversHiddenParts = false
			end
			if extent.MaxY < plan.Finish.Y + plan.Finish.SizeY / 2 then
				coversHiddenParts = false
			end
			if (extent.MaxY - extent.MinY) <= (deckHigh - deckLow) then
				tallerThanDecks = false
			end
		end
	end
	check("extent covers the void slab and the finish banner", coversHiddenParts)
	check("extent is taller than the platforms alone", tallerThanDecks)
end

do
	-- Identical courses on every server is what makes the per-stage top-100
	-- boards comparable at all -- two players' times are only the same
	-- measurement if they ran the same geometry.
	local identical = true
	for _, stage in Stages do
		if stage.Generated then
			local a, b = StageLayout.Build(stage), StageLayout.Build(stage)
			for i, platform in a.Platforms do
				local other = b.Platforms[i]
				if platform.X ~= other.X or platform.Y ~= other.Y or platform.Z ~= other.Z then
					identical = false
				end
			end
		end
	end
	check("courses are byte-identical between builds", identical)
end

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
	for _, name in failures do
		print("  FAILED: " .. name)
	end
	os.exit(1)
end
