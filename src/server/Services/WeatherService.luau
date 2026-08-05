local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Decides which stage's weather each player should be seeing, and tells that
-- player's client to apply it. The actual Lighting work happens on the client
-- (see WeatherController).
--
-- This used to tween the SERVER's Lighting directly, which replicates to
-- everyone automatically -- correct only while exactly one race could exist
-- at a time. With races running in parallel, two groups can be on Stage 2
-- (storm) and Stage 3 (night) simultaneously, and a Roblox server has exactly
-- ONE Lighting: there is no server-side value that is right for both. Weather
-- is a purely visual, per-viewer concern, so it belongs on the client.
--
-- Moving it also lifted an old limitation: bot, practice and duel matches
-- deliberately ran with no weather at all, precisely because they couldn't
-- safely touch the global singleton while a real race might be using it.
-- They now get the same weather as any other race.
--
-- The server no longer touches Lighting AT ALL, deliberately: any server-side
-- write replicates down and would stomp whatever the client had set for
-- itself, which is exactly the bug this change exists to remove.
local WeatherService = {}

local weatherRemote: RemoteEvent

-- Last value sent per player, so callers can push on every tick without
-- spamming the wire -- only an actual change is sent. `everSent` is separate
-- because nil is a meaningful value here (the lobby), so it can't double as
-- "nothing sent yet".
local lastSent: { [number]: string? } = {}
local everSent: { [number]: boolean } = {}

-- A private-server host can pin the sky (see HostControlService), overriding
-- whatever the stage would otherwise bring with it. Server-wide rather than
-- per-player: it is one host setting one look for one room.
--
-- Note this changes only the WEATHER, never the stage -- a host who wants a
-- night race on Stage 2 gets Stage 2 with a night sky, not Stage 5.
local override: string? = nil

-- Part of the dedup key, not just the payload. Without it, a player already
-- looking at Stage 3 would be skipped as unchanged when the host switched the
-- sky, and would be the only one left on the old weather.
local lastOverride: { [number]: string? } = {}

-- stageId, or nil for "back to the lobby look".
function WeatherService.SetForPlayer(player: Player, stageId: string?)
	if not weatherRemote then
		return
	end
	local userId = player.UserId
	if everSent[userId] and lastSent[userId] == stageId and lastOverride[userId] == override then
		return
	end
	lastSent[userId] = stageId
	lastOverride[userId] = override
	everSent[userId] = true
	weatherRemote:FireClient(player, stageId, override)
end

-- Applies a new host override and re-pushes to everyone who already has a
-- weather, so the change is felt immediately rather than at whatever the next
-- race happens to be. The lobby (stageId nil) is included deliberately: the
-- host is standing in it when they pick, and a control whose effect you cannot
-- see until you leave the room is a control nobody trusts.
function WeatherService.SetOverride(presetName: string?)
	if override == presetName then
		return
	end
	override = presetName
	for _, player in Players:GetPlayers() do
		if everSent[player.UserId] then
			WeatherService.SetForPlayer(player, lastSent[player.UserId])
		end
	end
end

function WeatherService.GetOverride(): string?
	return override
end

function WeatherService.Forget(player: Player)
	lastSent[player.UserId] = nil
	lastOverride[player.UserId] = nil
	everSent[player.UserId] = nil
end

function WeatherService.Init()
	weatherRemote = Net.CreateRemoteEvent(RemoteNames.WeatherChanged)
end

return WeatherService
