local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")

local Widgets = require(script.Parent.Parent.Widgets)

-- Native Roblox friend-invite prompt -- no external dependency, and every
-- accepted invite is a free new player, so this is one of the highest
-- leverage/lowest effort growth levers available.
local InviteFriendsController = {}

local player = Players.LocalPlayer

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "InviteFriendsGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local button = Widgets.Button("Invite Friends", UDim2.fromOffset(200, 48), UDim2.new(1, -210, 1, -68), {
		Variant = "Success",
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
