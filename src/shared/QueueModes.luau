-- Lobby teleport stations: one physical pad per race size, plus the PLAY
-- button's original "any size" queue.
--
-- Each station is its OWN queue. That is the whole point of the feature and
-- also its main cost, so it's worth stating plainly: splitting one population
-- across several queues means each queue fills more slowly than the single
-- shared one did, and a 5-player station on a quiet server may never fill at
-- all. Two things keep that from being a dead end:
--   * the PLAY button still feeds the size-agnostic queue (Target = 0), which
--     starts on Constants.Match.MinPlayers and stays the fastest way into a
--     race, so nobody is ever forced through a station;
--   * every queue shows an elapsed clock and offers "PLAY WITH BOTS" once the
--     wait stalls (see QueueStatusController), so a station that can't fill
--     still resolves into something playable.
--
-- Stations are exact-fill: a 4-player station starts the instant the 4th
-- player steps on, with no matching window to wait out (there is nothing left
-- to wait FOR -- the group is complete). The size-agnostic queue keeps its
-- Constants.Match.MatchingSeconds window, since there "how many" is exactly
-- the open question.
export type Mode = {
	Id: string,
	Label: string,
	-- Exact number of racers required. 0 means "any size" -- the PLAY
	-- button's queue, floored at Constants.Match.MinPlayers.
	Target: number,
	-- Custom stations ask the player for a number instead of carrying one.
	Custom: boolean?,
}

local QueueModes = {}

-- Order here is the order the pads are laid out in the lobby.
local Stations: { Mode } = {
	{ Id = "Duo", Label = "1 v 1", Target = 2 },
	{ Id = "Trio", Label = "3 PLAYERS", Target = 3 },
	{ Id = "Quad", Label = "4 PLAYERS", Target = 4 },
	{ Id = "Five", Label = "5 PLAYERS", Target = 5 },
	{ Id = "Custom", Label = "CUSTOM", Target = 0, Custom = true },
}
QueueModes.Stations = Stations

-- Bounds for a custom station's picker. The floor matches
-- Constants.Match.MinPlayers (a race needs a real opponent); the ceiling is a
-- practical limit on how many racers a stage's spawn area can hold without
-- players stacking inside each other.
QueueModes.CustomMin = 2
QueueModes.CustomMax = 8

-- Target = 0 is the size-agnostic queue the PLAY button uses.
QueueModes.AnySize = 0

function QueueModes.IsValidTarget(target: number): boolean
	if target == QueueModes.AnySize then
		return true
	end
	return target == math.floor(target) and target >= QueueModes.CustomMin and target <= QueueModes.CustomMax
end

function QueueModes.LabelForTarget(target: number): string
	if target == QueueModes.AnySize then
		return "ANY SIZE"
	end
	if target == 2 then
		return "1 v 1"
	end
	return ("%d PLAYERS"):format(target)
end

return QueueModes
