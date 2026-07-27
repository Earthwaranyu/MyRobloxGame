local Players = game:GetService("Players")

-- Single place that turns a UserId into that player's actual profile picture
-- -- the round headshot of their equipped avatar (hats/hair/costume included)
-- that Roblox renders server-side, the same image the profile card shows.
--
-- Why this exists rather than each caller just assigning an
-- "rbxthumb://type=AvatarHeadShot&id=..." string: that URL form is accepted
-- by the engine but is NOT guaranteed to ever render. Confirmed live
-- (execute_luau against several UserIds): for an account that was never
-- issued -- which includes the simulated "Player1"/"Player2" clients Studio
-- Team Test hands out, Roblox's own convention being negative/zero UserIds --
-- there is no render job that will ever finish, so the image silently stays
-- blank forever. GetUserThumbnailAsync exposes that as a second `isReady`
-- return, which is the only way to tell "still loading" apart from "never
-- coming" and show a deliberate placeholder instead of an accidental-looking
-- empty circle.
local AvatarThumbnail = {}

-- Per Roblox's docs, isReady=false means `content` is just a placeholder and
-- the real thumbnail needs a retry after a short delay.
local MAX_ATTEMPTS = 4
local RETRY_DELAY = 1

-- userId -> resolved content string. Only ever holds confirmed-ready results,
-- so a second caller for the same player (finishing a race and starting
-- another against the same opponent, say) renders instantly with no refetch.
local cache: { [number]: string } = {}

-- Calls `onReady(content)` once, if and only if a real rendered thumbnail
-- exists. Never calls it otherwise -- callers are expected to have already
-- drawn whatever placeholder they want to keep in that case. Yields
-- internally, so it always runs off to the side and returns immediately.
function AvatarThumbnail.Load(userId: number, onReady: (content: string) -> ())
	local cached = cache[userId]
	if cached then
		onReady(cached)
		return
	end

	task.spawn(function()
		for _ = 1, MAX_ATTEMPTS do
			local ok, content, isReady = pcall(function()
				return Players:GetUserThumbnailAsync(
					userId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size150x150
				)
			end)

			if not ok then
				warn(
					("AvatarThumbnail: GetUserThumbnailAsync failed for userId %d (%s)"):format(
						userId,
						tostring(content)
					)
				)
				return
			end

			if isReady then
				cache[userId] = content
				onReady(content)
				return
			end

			task.wait(RETRY_DELAY)
		end
	end)
end

return AvatarThumbnail
