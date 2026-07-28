return {
	WalkSpeed = 16,
	SprintSpeed = 24,

	Elo = {
		StartingRating = 0,
		KFactor = 32,
	},

	Leaderboard = {
		TopCount = 100,
	},

	-- Per-ability numbers (Dash's cooldown/speed/duration included) now live
	-- in shared/Abilities.luau -- one table per ability instead of scattered
	-- across Constants, since there are several abilities now, not just Dash.

	-- Ghost recording samples the racer's own position on a fixed clock
	-- (rather than storing a timestamp per sample) so both the recorder and
	-- the playback side can agree on "where was I at time t" from nothing
	-- more than the sample's index in the array.
	Ghost = {
		SampleIntervalSeconds = 0.15,
	},

	Match = {
		-- Not strict 1v1: a race is however many players (or a party) queue
		-- within the matching window, no upper cap. Elo already extends
		-- correctly to N players (the winner's gain is the sum of beating
		-- each opponent still racing individually -- see PlayerReachedFinish),
		-- and the spectate "pick who to watch" feature only really matters
		-- once there's more than one racer left after the first finish. This
		-- is just the floor: fewer than this and a race can't start at all.
		MinPlayers = 2,
		-- The shared queue's matchmaking window: how long a countdown runs,
		-- once MinPlayers is met, before the map is picked and everyone is
		-- teleported. Anyone who clicks PLAY during it joins the SAME race,
		-- so this is the single number that decides how big races get.
		--
		-- Was 3, which is why PLAY felt like a 1v1 mode despite having no
		-- upper limit on racers -- only players who clicked within the same
		-- 3-second window ever got grouped, and outside of a coordinated
		-- party that's almost never more than two people. Widening it is the
		-- cheap way to get real multiplayer races without splitting the
		-- population across separate per-size queues (which would starve all
		-- of them at low player counts).
		MatchingSeconds = 12,
		-- Bot/practice/duel reuse the queue's reveal + countdown pacing so the
		-- client UI needs no mode-specific handling -- but they have NOTHING
		-- to wait for: the opponent is a bot, a ghost, or an already-accepted
		-- challenge. They get their own (short) value so widening the real
		-- matchmaking window above doesn't tax them with dead time.
		SoloRevealSeconds = 3,
		-- How long before MatchingSeconds ends the case-opening map reveal
		-- spins for; the reel lands exactly as the group gets teleported.
		MapRevealSeconds = 2.5,
		-- The "RACE STARTING IN" countdown that plays on the map itself,
		-- after the group has been teleported there but before the race
		-- actually starts (first-person, timer, finish-line detection).
		CountdownSeconds = 8,
		MaxDurationSeconds = 300,
		PointsPerWin = 50,
		-- Paid to anyone who CROSSES THE LINE, winner or not, on top of
		-- PointsPerWin for the one who got there first.
		--
		-- Without it a race paid exactly one player and everybody else walked
		-- away with nothing -- and in a field of N, that's (N-1)/N of all race
		-- outcomes. Losing already costs Elo; losing and also being told your
		-- last two minutes earned literally zero is what teaches people to
		-- stop queueing. Deliberately far below PointsPerWin so winning is
		-- still overwhelmingly the point, and deliberately gated on FINISHING
		-- -- quitting or falling out pays nothing, so it can't be farmed by
		-- queueing and immediately leaving.
		PointsPerFinish = 15,
	},
}
