local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local RankTiers = require(Shared.RankTiers)

local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

-- Small always-visible corner readout so rank/elo/points progress is felt
-- constantly, not just when the Shop panel happens to be open.
local StatsPillController = {}

local player = Players.LocalPlayer

local dot: Frame
local label: TextLabel

-- The last profile the server sent, so the pill can be re-rendered on a viewport
-- change without another round trip -- the text format depends on the tier.
local lastProfile: { Elo: number, Points: number }? = nil

local function render()
	local profile = lastProfile
	if not profile then
		return
	end

	local rankName = RankTiers.GetRankForElo(profile.Elo)
	local rankColor = Theme.GetRankColor(rankName)

	dot.BackgroundColor3 = rankColor
	-- Compact on a phone. The full form ("Bronze  1000 elo  •  1293 pts") needs
	-- more width than the pill has once everything scales down -- measured on the
	-- emulator at 137px of label for a string wanting well over that, so it
	-- rendered as "Bronze  1000 elo  •...". Dropping the unit words keeps every
	-- number the player actually reads.
	if Responsive.Tier() == "Phone" then
		label.Text = ("%s  %d  •  %d"):format(rankName, profile.Elo, profile.Points)
	else
		label.Text = ("%s  %d elo  •  %d pts"):format(rankName, profile.Elo, profile.Points)
	end
end

local function refresh()
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if not profile then
		return
	end
	lastProfile = profile
	render()
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StatsPillGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local pill = Widgets.StatPill(
		UDim2.fromOffset(Responsive.Px(230), Responsive.Px(32)),
		UDim2.fromOffset(Responsive.Px(10), Responsive.Px(14))
	)
	pill.Parent = screenGui

	dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(10, 10)
	dot.BackgroundColor3 = Theme.Color.TextMuted
	dot.BorderSizePixel = 0
	dot.LayoutOrder = 1
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot
	dot.Parent = pill

	label = Widgets.Label("", UDim2.fromOffset(Responsive.Px(190), Responsive.Px(32)), UDim2.fromOffset(0, 0), {
		TextSize = 14,
	})
	label.LayoutOrder = 2
	label.Parent = pill

	-- Re-lays out on a viewport change AND re-renders the text, because the
	-- pill's format is tier-dependent -- a device crossing the phone threshold
	-- needs the shorter string, not just a smaller box.
	Responsive.Observe(function()
		pill.Size = UDim2.fromOffset(Responsive.Px(230), Responsive.Px(32))
		pill.Position = UDim2.fromOffset(Responsive.Px(10), Responsive.Px(14))
		label.Size = UDim2.fromOffset(Responsive.Px(190), Responsive.Px(32))
		label.TextSize = Responsive.Text(14)
		dot.Size = UDim2.fromOffset(Responsive.Px(10), Responsive.Px(10))
		render()
	end)
end

function StatsPillController.Init()
	buildUI()
	refresh()

	local remote = Net.GetRemoteEvent(RemoteNames.RaceOutcome)
	remote.OnClientEvent:Connect(function()
		task.wait(0.1)
		refresh()
	end)

	task.spawn(function()
		while true do
			task.wait(5)
			refresh()
		end
	end)
end

return StatsPillController
