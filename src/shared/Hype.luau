local RankTiers = require(script.Parent.RankTiers)

-- Server-wide announcements: the things that happen to ONE player but that
-- everybody in the server sees.
--
-- Until this existed the game had no broadcast at all -- not a single
-- FireAllClients anywhere on the server. Every player sat in a private
-- bubble: you could rank up, take a stage record, or win five in a row and
-- nobody would ever know. That is a real cost on Roblox specifically, where
-- what makes a server sticky is the sense that other people are there and
-- doing things worth beating. These three moments are the ones worth
-- interrupting everyone for -- rare enough that a toast stays an event, and
-- all three are things another player can go and try to take from you.
--
-- Formatting lives HERE rather than on either side alone so the server and
-- the client can't drift on wording: the server sends the facts (who, what,
-- how much), the client renders them through Hype.Describe.
local Hype = {}

export type Kind = "RankUp" | "WinStreak" | "StageRecord"

export type Announcement = {
	Kind: Kind,
	PlayerName: string,
	-- RankUp
	RankName: string?,
	-- WinStreak
	Streak: number?,
	-- StageRecord
	StageName: string?,
	TimeSeconds: number?,
	PreviousHolder: string?,
	PreviousSeconds: number?,
}

export type Presentation = {
	Icon: string,
	Color: Color3,
	Headline: string,
	Detail: string?,
}

-- Win streaks announce at MILESTONES only: 3, 5, 10, then every 5.
--
-- Three is where a streak stops being luck and starts being a claim someone
-- else in the server might want to end. But a plain ">= 3" floor announced
-- every single win from there on, so one player on a hot run could hold the
-- whole feed -- one toast per race, indefinitely. That is the exact "train
-- everyone to ignore the feed" failure the threshold existed to prevent, and
-- it would have cost the rarer rank-up and record toasts their impact too.
--
-- Milestones fix it in both directions: a streak stays an event, and a long
-- run escalates (3 -> 5 -> 10 -> 15) instead of repeating itself.
Hype.FirstStreakMilestone = 3

function Hype.ShouldAnnounceStreak(streak: number): boolean
	if streak == 3 or streak == 5 then
		return true
	end
	-- 10, 15, 20, ... -- gated on >= 10 so this can't also catch 5.
	return streak >= 10 and streak % 5 == 0
end

local FALLBACK_COLOR = Color3.fromRGB(255, 205, 60)

local function formatTime(seconds: number): string
	return ("%d:%05.2f"):format(math.floor(seconds / 60), seconds % 60)
end

-- Rank toasts take the tier's OWN color, the same one used on nameplates,
-- profile cards and the rank board -- so "Gold" always looks like Gold
-- wherever a player meets it, rather than teaching a fourth visual language
-- for the same seven ranks.
local function rankColor(rankName: string?): Color3
	if not rankName then
		return FALLBACK_COLOR
	end
	for _, tier in RankTiers.Tiers do
		if tier.Name == rankName then
			return tier.Color
		end
	end
	return FALLBACK_COLOR
end

function Hype.Describe(announcement: Announcement): Presentation
	local name = announcement.PlayerName

	if announcement.Kind == "RankUp" then
		return {
			Icon = "Rank",
			Color = rankColor(announcement.RankName),
			Headline = ("%s just hit %s!"):format(name, string.upper(announcement.RankName or "")),
		}
	end

	if announcement.Kind == "WinStreak" then
		return {
			Icon = "Streak",
			Color = Color3.fromRGB(255, 138, 61),
			Headline = ("%s is on a %d WIN STREAK!"):format(name, announcement.Streak or 0),
		}
	end

	-- StageRecord. The previous holder is named in the detail line on purpose:
	-- "beat a time" is a statistic, "beat SIAJUIZ" is a rivalry, and the whole
	-- point of broadcasting this is to give someone a reason to queue again.
	local detail
	if announcement.PreviousHolder and announcement.PreviousSeconds then
		detail = ("%s beat %s's %s"):format(
			name,
			announcement.PreviousHolder,
			formatTime(announcement.PreviousSeconds)
		)
	else
		detail = ("set by %s"):format(name)
	end

	return {
		Icon = "Record",
		Color = Color3.fromRGB(108, 178, 255),
		Headline = ("NEW RECORD  %s  %s"):format(
			announcement.StageName or "?",
			formatTime(announcement.TimeSeconds or 0)
		),
		Detail = detail,
	}
end

return Hype
