-- How a remaining-time value becomes the number a player reads.
--
-- Two separate cards count down to the SAME moment -- the wave clock at the top
-- of the screen ("NEXT WAVE 0:51", WaveClockController) and the queue card in
-- the middle ("52", QueueStatusController) -- and they disagreed by a second
-- for essentially the entire countdown. Not drift: the server sends both the
-- same number from the same `waveDepartsAt`, and both tick locally off
-- os.clock(). They disagreed because one displayed math.floor and the other
-- math.ceil of the same quantity, so any fractional remainder -- which is to
-- say, always -- rounded two different ways. At 51.4s left that is "0:51"
-- beside "52", which is exactly what a player screenshots.
--
-- CEILING is the correct convention for a countdown, and the reason is worth
-- stating: with 0.4 seconds left, flooring shows "0" for a whole second before
-- anything happens, so the clock lies at the one moment it is being watched
-- hardest. Ceiling shows "1" until the instant it becomes 0. WaveClockController
-- already ceilinged for its once-per-second pulse while flooring the text, so
-- its own animation was a second out of step with its own label.
--
-- Pure arithmetic in shared/ rather than a helper in one controller, so
-- tests/run.sh can assert the two forms never disagree again -- the property
-- that actually broke.
local Countdown = {}

-- The whole number of seconds to SHOW for `remaining` seconds left.
--
-- Clamped at 0 so a deadline that has already passed reads "0" rather than a
-- negative, which callers would otherwise each have to guard separately.
function Countdown.Seconds(remaining: number): number
	return math.max(0, math.ceil(remaining))
end

-- The same value as m:ss, for the cards that show a clock rather than a bare
-- number.
--
-- Decomposes AFTER rounding, which is the part that is easy to get wrong:
-- ceiling 59.6 gives 60, and formatting minutes/seconds from the raw remainder
-- would print "0:60". Splitting the already-rounded second gives "1:00".
function Countdown.Clock(remaining: number): string
	local seconds = Countdown.Seconds(remaining)
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

return Countdown
