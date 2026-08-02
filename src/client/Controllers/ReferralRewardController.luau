local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- Pops once for each side of a referral payout (see ReferralService): the
-- veteran the instant the friend they partied up with finishes that friend's
-- very first real race, and the newcomer themself for the matching welcome
-- bonus. Same toast shape as DailyRewardController, just two possible
-- messages depending on which side of the payout this client is.
local ReferralRewardController = {}

-- Reference geometry; the real numbers come from the layout pass in buildUI.
local PANEL_WIDTH, PANEL_HEIGHT = 400, 150

local player = Players.LocalPlayer

local panel: CanvasGroup
local titleLabel: TextLabel
local detailLabel: TextLabel

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ReferralRewardGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 11
	screenGui.Parent = player:WaitForChild("PlayerGui")

	panel = Widgets.Panel(UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT), UDim2.new(0.5, -PANEL_WIDTH / 2, 0.32, 0))
	panel.Parent = screenGui

	titleLabel = Widgets.Label("", UDim2.new(1, -20, 0, 34), UDim2.fromOffset(10, 14), {
		Font = Theme.Font.Display,
		TextSize = 24,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.Success,
	})
	titleLabel.Parent = panel

	detailLabel = Widgets.Label("", UDim2.new(1, -20, 0, 56), UDim2.fromOffset(10, 56), {
		TextSize = 18,
		Align = Enum.TextXAlignment.Center,
	})
	detailLabel.Parent = panel

	-- This toast had no responsive pass at all: a flat 400x150 at raw offsets,
	-- which is wider than a 375pt portrait screen and sat unscaled on every
	-- device. It fires once, on a player's very first race, so nobody would ever
	-- catch it in testing -- and being a fixed-size card that only ever appears
	-- for a few seconds is exactly what let it go unnoticed.
	Responsive.Observe(function()
		local px, tx = Responsive.Px, Responsive.Text
		local viewport = Responsive.ViewportSize()
		local width = math.min(px(PANEL_WIDTH), viewport.X - Responsive.ScreenMargin * 2)
		local height = px(PANEL_HEIGHT)

		panel.Size = UDim2.fromOffset(width, height)
		panel.Position = UDim2.fromOffset(
			math.round((viewport.X - width) / 2),
			Responsive.ClampY(math.round(viewport.Y * 0.32), height)
		)

		local pad = px(10)
		titleLabel.Size = UDim2.new(1, -pad * 2, 0, px(34))
		titleLabel.Position = UDim2.fromOffset(pad, px(14))
		titleLabel.TextSize = tx(24)

		detailLabel.Size = UDim2.new(1, -pad * 2, 0, px(56))
		detailLabel.Position = UDim2.fromOffset(pad, px(56))
		detailLabel.TextSize = tx(18)
	end)
end

local function show(data: { Role: string, FriendName: string?, Reward: number })
	if data.Role == "Veteran" then
		titleLabel.Text = "FRIEND BROUGHT IN!"
		detailLabel.Text = ("%s raced with you  •  +%d points"):format(data.FriendName or "Your friend", data.Reward)
	else
		titleLabel.Text = "WELCOME BONUS"
		detailLabel.Text = ("First race complete  •  +%d points"):format(data.Reward)
	end
	Sounds.Play("Purchase")

	Widgets.Open(panel)
	task.wait(3.4)
	Widgets.Close(panel)
end

function ReferralRewardController.Init()
	buildUI()

	local remote = Net.GetRemoteEvent(RemoteNames.ReferralReward)
	remote.OnClientEvent:Connect(show)
end

return ReferralRewardController
