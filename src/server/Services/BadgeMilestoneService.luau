local BadgeService = game:GetService("BadgeService")

-- Badges show up on a player's public Roblox profile -- free, platform-level
-- exposure for the game every time someone earns one, so milestone badges
-- are one of the highest-leverage growth levers available on Roblox
-- specifically. Badge OBJECTS have to be created by a human on the Creator
-- Dashboard (Experience > Badges) though -- there's no way to do that from
-- game code -- so every id below starts at 0 (award() no-ops on 0) until
-- someone pastes in the real ids here.
local BADGE_IDS = {
	FirstWin = 0,
	WinStreak3 = 0,
	WinStreak5 = 0,
	RankSilver = 0,
	RankGold = 0,
	RankPlatinum = 0,
	RankDiamond = 0,
	RankMaster = 0,
	RankGrandmaster = 0,
}

local BadgeMilestoneService = {}

local function award(player: Player, profile: { [string]: any }, key: string)
	local badgeId = BADGE_IDS[key]
	if not badgeId or badgeId == 0 then
		return
	end

	profile.AwardedBadgeKeys = profile.AwardedBadgeKeys or {}
	if profile.AwardedBadgeKeys[key] then
		return
	end

	local ok, result = pcall(function()
		return BadgeService:AwardBadge(player.UserId, badgeId)
	end)
	if ok and result then
		profile.AwardedBadgeKeys[key] = true
	end
end

function BadgeMilestoneService.CheckWinMilestones(player: Player, profile: { [string]: any })
	award(player, profile, "FirstWin")
	if profile.WinStreak >= 3 then
		award(player, profile, "WinStreak3")
	end
	if profile.WinStreak >= 5 then
		award(player, profile, "WinStreak5")
	end
end

local RANK_BADGE_KEYS = {
	Silver = "RankSilver",
	Gold = "RankGold",
	Platinum = "RankPlatinum",
	Diamond = "RankDiamond",
	Master = "RankMaster",
	Grandmaster = "RankGrandmaster",
}

function BadgeMilestoneService.CheckRankMilestone(player: Player, profile: { [string]: any }, rankName: string)
	local key = RANK_BADGE_KEYS[rankName]
	if key then
		award(player, profile, key)
	end
end

return BadgeMilestoneService
