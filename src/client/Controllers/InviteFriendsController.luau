local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

-- Native Roblox friend-invite prompt -- no external dependency, and every
-- accepted invite is a free new player, so this is one of the highest
-- leverage/lowest effort growth levers available. The caption below it is
-- what actually makes the button worth pressing: SocialService gives game
-- code no attribution for who invited whom, so the real payout (see
-- ReferralService) triggers off partying up and racing together, not off
-- this click -- but the player has no way to know that reward exists at all
-- without this label telling them.
local InviteFriendsController = {}

local player = Players.LocalPlayer

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "InviteFriendsGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local captionPill = Widgets.StatPill(UDim2.fromOffset(200, 24), UDim2.new(1, -210, 1, -96))
	captionPill.Parent = screenGui

	local captionLabel = Widgets.Label("+300 pts together!", UDim2.fromOffset(176, 24), UDim2.fromOffset(0, 0), {
		TextSize = 12,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.Warning,
		Bold = false,
	})
	captionLabel.Parent = captionPill

	local button = Widgets.Button("Invite Friends", UDim2.fromOffset(200, 48), UDim2.new(1, -210, 1, -68), {
		Variant = "Success",
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Invite", color)
		end,
	})
	button.Parent = screenGui

	button.MouseButton1Click:Connect(function()
		local ok, canInvite = pcall(function()
			return SocialService:CanSendGameInviteAsync(player)
		end)
		if ok and canInvite then
			pcall(function()
				SocialService:PromptGameInvite(player)
			end)
		end
	end)
end

function InviteFriendsController.Init()
	buildUI()
end

return InviteFriendsController
