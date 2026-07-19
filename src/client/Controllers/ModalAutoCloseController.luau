local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Any panel opened through Widgets.Modal (Shop, Gacha, Party, Settings,
-- Emotes, Leaderboard, ProfileCard, ...) used to stay open across a queued
-- race actually starting -- if the countdown finished while someone was
-- browsing the shop, the race began first-person with their whole screen
-- still covered by a shop panel and its backdrop, no way to see (or react
-- to) it short of manually finding the ✕. Force-closing everything the
-- instant the client flips to "Racing" fixes it for every panel at once,
-- not just whichever one happened to be open when this was reported.
local ModalAutoCloseController = {}

function ModalAutoCloseController.Init()
	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Racing" then
			Widgets.CloseAllModals()
		end
	end)
end

return ModalAutoCloseController
