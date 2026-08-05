local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local PrivateServer = require(Shared.PrivateServer)
local RemoteNames = require(Shared.RemoteNames)
local RankTiers = require(Shared.RankTiers)

local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

-- Small always-visible corner readout so rank/elo/points progress is felt
-- constantly, not just when the Shop panel happens to be open.
local StatsPillController = {}

local player = Players.LocalPlayer

local pill: Frame
local dot: Frame
local label: TextLabel

-- A private server pays no rating and no points (Shared.PrivateServer), and a
-- player who has not been told that reads a race which moved none of their
-- numbers as a bug -- or worse, as lost progress. The marker rides the
-- always-visible pill rather than a toast at race end because the state lasts
-- the entire session: there is no moment during it when it stops being true.
local CASUAL_SUFFIX = "  •  CASUAL"

-- The pill is a fixed width whose label already truncates on a phone, so the
-- extra word has to buy its own room instead of sharing the existing budget.
-- Sized against the longest form the label can hold ("Bronze  1000 elo  •
-- 59083 pts" plus the suffix) at the pill's 14px text.
local CASUAL_EXTRA_WIDTH = 74

local PILL_WIDTH, LABEL_WIDTH = 230, 190

-- Starts false and is corrected by PrivateServer.ObserveCasual once the server
-- has published, which can land after this pill is already on screen -- the
-- client cannot answer the question by itself at all. So the marker is applied
-- reactively rather than read once at build time.
local casual = false

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
	local suffix = if casual then CASUAL_SUFFIX else ""
	if Responsive.Tier() == "Phone" then
		label.Text = ("%s  %d  •  %d%s"):format(rankName, profile.Elo, profile.Points, suffix)
	else
		label.Text = ("%s  %d elo  •  %d pts%s"):format(rankName, profile.Elo, profile.Points, suffix)
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

-- Size and text together, since the marker changes both: the pill is a fixed
-- width and gets wider to carry the extra word rather than squeezing it into
-- the budget the numbers already need. Re-run on a viewport change and on the
-- casual flag arriving.
local function applyLayout()
	local extra = if casual then CASUAL_EXTRA_WIDTH else 0
	pill.Size = UDim2.fromOffset(Responsive.Px(PILL_WIDTH + extra), Responsive.Px(32))
	pill.Position = UDim2.fromOffset(Responsive.Px(10), Responsive.Px(14))
	label.Size = UDim2.fromOffset(Responsive.Px(LABEL_WIDTH + extra), Responsive.Px(32))
	label.TextSize = Responsive.Text(14)
	dot.Size = UDim2.fromOffset(Responsive.Px(10), Responsive.Px(10))
	render()
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StatsPillGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	pill = Widgets.StatPill(
		UDim2.fromOffset(Responsive.Px(PILL_WIDTH), Responsive.Px(32)),
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

	label = Widgets.Label("", UDim2.fromOffset(Responsive.Px(LABEL_WIDTH), Responsive.Px(32)), UDim2.fromOffset(0, 0), {
		TextSize = 14,
	})
	label.LayoutOrder = 2
	label.Parent = pill

	-- Re-lays out on a viewport change AND re-renders the text, because the
	-- pill's format is tier-dependent -- a device crossing the phone threshold
	-- needs the shorter string, not just a smaller box.
	Responsive.Observe(applyLayout)

	PrivateServer.ObserveCasual(function(isCasual)
		casual = isCasual
		applyLayout()
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
