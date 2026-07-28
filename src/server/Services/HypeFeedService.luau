local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Hype = require(Shared.Hype)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

-- Broadcasts the rare, brag-worthy moments to everyone in the server (see
-- Hype.luau for why these three and not others).
--
-- Server-authoritative by construction: every Announce call site here is
-- reached from code that has already committed the thing to a profile or a
-- DataStore, so a client can neither fake an announcement nor suppress one
-- about itself. There is no client->server direction on this remote at all.
local HypeFeedService = {}

local announcementRemote: RemoteEvent

local function stageName(stageId: string): string
	for _, stage in Stages do
		if stage.Id == stageId then
			return stage.Name
		end
	end
	return stageId
end

local function announce(payload: Hype.Announcement)
	if not announcementRemote then
		return
	end
	announcementRemote:FireAllClients(payload)
end

function HypeFeedService.AnnounceRankUp(player: Player, rankName: string)
	announce({ Kind = "RankUp", PlayerName = player.DisplayName, RankName = rankName })
end

function HypeFeedService.AnnounceWinStreak(player: Player, streak: number)
	if not Hype.ShouldAnnounceStreak(streak) then
		return
	end
	announce({ Kind = "WinStreak", PlayerName = player.DisplayName, Streak = streak })
end

-- Best time per stage FOR THIS SERVER, not the global all-time record.
--
-- Deliberate: a global record check would mean an OrderedDataStore read on
-- every single finish, and the answer would still usually be "no". The
-- in-server best costs nothing, updates instantly, and is the version that
-- actually drives the behaviour this feature exists for -- the person whose
-- time was just beaten is sitting in the server able to queue up and take it
-- straight back, which an all-time record held by someone offline is not.
local bestTimes: { [string]: { seconds: number, holder: string } } = {}

-- Returns whether this became the server's new best, so callers can decide
-- whether they also want to react to it (nobody does yet).
function HypeFeedService.CheckStageRecord(player: Player, stageId: string, timeSeconds: number): boolean
	local previous = bestTimes[stageId]
	if previous and timeSeconds >= previous.seconds then
		return false
	end

	bestTimes[stageId] = { seconds = timeSeconds, holder = player.DisplayName }

	-- The FIRST finish on a stage sets the bar silently. Announcing it would
	-- fire "NEW RECORD" on every stage's first completion after each server
	-- start -- once per stage per server, for a time nobody was competing
	-- against -- which is exactly the kind of hollow notification that teaches
	-- players to stop reading the feed.
	if not previous then
		return true
	end

	announce({
		Kind = "StageRecord",
		PlayerName = player.DisplayName,
		StageName = stageName(stageId),
		TimeSeconds = timeSeconds,
		PreviousHolder = previous.holder,
		PreviousSeconds = previous.seconds,
	})
	return true
end

function HypeFeedService.Init()
	announcementRemote = Net.CreateRemoteEvent(RemoteNames.HypeAnnouncement)
end

return HypeFeedService
