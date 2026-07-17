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

	Match = {
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
