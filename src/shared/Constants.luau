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

	-- Free, universal, equal-for-everyone mobility tool -- not a random
	-- pickup or a Robux-gated perk, on purpose: this game's whole identity is
	-- a skill-based Elo ladder, and anything that makes race outcomes depend
	-- on luck or spend instead of skill undermines that. A short-cooldown
	-- dash raises the platforming skill ceiling (route choices, saving a
	-- botched jump) without touching who's "allowed" to win.
	Ability = {
		DashCooldownSeconds = 4,
		DashSpeed = 55,
		DashDurationSeconds = 0.18,
	},

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
		-- Brief matchmaking window before the map is picked and everyone is
		-- teleported: touch a start line / click Play, wait a beat for other
		-- players to join, then the case-opening reveal spins during the last
		-- MapRevealSeconds of it.
		MatchingSeconds = 3,
		-- How long before MatchingSeconds ends the case-opening map reveal
		-- spins for; the reel lands exactly as the group gets teleported.
		MapRevealSeconds = 2.5,
		-- The "RACE STARTING IN" countdown that plays on the map itself,
		-- after the group has been teleported there but before the race
		-- actually starts (first-person, timer, finish-line detection).
		CountdownSeconds = 8,
		MaxDurationSeconds = 300,
		PointsPerWin = 50,
	},
}
