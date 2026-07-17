local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local RankTiers = require(Shared.RankTiers)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

-- Small always-visible corner readout so rank/elo/points progress is felt
-- constantly, not just when the Shop panel happens to be open.
local StatsPillController = {}

local player = Players.LocalPlayer

local dot: Frame
local label: TextLabel

local function refresh()
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if not profile then
		return
	end

	local rankName = RankTiers.GetRankForElo(profile.Elo)
	local rankColor = Theme.GetRankColor(rankName)

	dot.BackgroundColor3 = rankColor
	label.Text = ("%s  %d elo  •  %d pts"):format(rankName, profile.Elo, profile.Points)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StatsPillGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local pill = Widgets.StatPill(UDim2.fromOffset(230, 32), UDim2.fromOffset(10, 14))
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

	label = Widgets.Label("", UDim2.fromOffset(190, 32), UDim2.fromOffset(0, 0), {
		TextSize = 14,
	})
	label.LayoutOrder = 2
	label.Parent = pill
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
