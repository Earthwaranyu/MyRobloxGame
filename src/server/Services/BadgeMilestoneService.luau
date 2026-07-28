local BadgeService = game:GetService("BadgeService")

-- Badges show up on a player's public Roblox profile -- free, platform-level
-- exposure for the game every time someone earns one.
--
-- Only the badges that actually EXIST are listed here. This used to also
-- carry win-streak (3/5) and per-rank (Silver..Grandmaster) entries set to
-- id 0, as placeholders for badges nobody had created yet -- award() no-ops
-- on 0, so all eight were dead weight that read like working features. Badge
-- objects can only be created by a human on the Creator Dashboard (Experience
-- > Badges), never from game code, so a placeholder id here is not a
-- to-do the code can ever resolve on its own.
--
-- To add one later: create the badge on the dashboard, add its real id below,
-- and call award() with the new key from wherever the milestone is detected.
local BADGE_IDS = {
	-- "Win Badge" -- confirmed live via BadgeService:GetBadgeInfoAsync.
	FirstWin = 805282398696077,
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
end

return BadgeMilestoneService
