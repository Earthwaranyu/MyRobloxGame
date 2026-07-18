local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local RankTiers = require(Shared.RankTiers)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- Server sends up to two RaceOutcome events per race: one economic (Won +
-- EloDelta) fired the instant a winner is decided, and one placement-only
-- event fired when this player personally crosses the line. See
-- MatchService.PlayerReachedFinish for the exact rules.
local RaceOutcomeController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local titleLabel: TextLabel
local detailLabel: TextLabel
local rankLabel: TextLabel
local streakLabel: TextLabel

local queue: { any } = {}
local processing = false

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RaceOutcomeGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- y = 0.55, well clear of QueueStatusController's countdown/"GO!" flash
	-- (both centered around y = 0.22-0.3), in case a race finishes fast enough
	-- for both to be on screen at once.
	panel = Widgets.Panel(UDim2.fromOffset(380, 196), UDim2.new(0.5, -190, 0.55, 0))
	panel.Parent = screenGui

	titleLabel = Widgets.Label("", UDim2.new(1, -20, 0, 50), UDim2.fromOffset(10, 16), {
		Font = Theme.Font.Display,
		TextSize = 34,
		Align = Enum.TextXAlignment.Center,
	})
	titleLabel.Parent = panel

	detailLabel = Widgets.Label("", UDim2.new(1, -20, 0, 28), UDim2.fromOffset(10, 70), {
		TextSize = 20,
		Align = Enum.TextXAlignment.Center,
	})
	detailLabel.Parent = panel

	rankLabel = Widgets.Label("", UDim2.new(1, -20, 0, 24), UDim2.fromOffset(10, 106), {
		TextSize = 16,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.TextSecondary,
	})
	rankLabel.Parent = panel

	streakLabel = Widgets.Label("", UDim2.new(1, -20, 0, 24), UDim2.fromOffset(10, 136), {
		Font = Theme.Font.Heading,
		TextSize = 17,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.Warning,
	})
	streakLabel.Parent = panel
end

local function applyRankUp(eloDelta: number)
	rankLabel.Text = ""

	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if not profile then
		return
	end

	local newElo = profile.Elo
	local oldElo = newElo - eloDelta
	local oldRank = RankTiers.GetRankForElo(oldElo)
	local newRank = RankTiers.GetRankForElo(newElo)

	if newRank == oldRank then
		return
	end

	rankLabel.Text = ("RANK UP  %s -> %s"):format(oldRank, newRank)
	rankLabel.TextColor3 = Theme.GetRankColor(newRank)
	task.delay(0.35, function()
		Sounds.Play("RankUp")
	end)
end

local function show(data: { Won: boolean, EloDelta: number?, Placement: number?, Total: number?, WinStreak: number?, StreakBonus: number? })
	streakLabel.Text = ""
	if data.Won then
		titleLabel.Text = "VICTORY!"
		titleLabel.TextColor3 = Theme.Color.Warning
		Sounds.Play("Victory")

		if data.WinStreak and data.WinStreak >= 2 then
			local bonusText = if data.StreakBonus and data.StreakBonus > 0 then (" (+%d pts)"):format(data.StreakBonus) else ""
			streakLabel.Text = ("🔥 %d WIN STREAK%s"):format(data.WinStreak, bonusText)
		end
	elseif data.EloDelta then
		titleLabel.Text = "DEFEAT"
		titleLabel.TextColor3 = Theme.Color.Danger
		Sounds.Play("Defeat")
	else
		titleLabel.Text = ("Finished #%d"):format(data.Placement or 0)
		titleLabel.TextColor3 = Theme.Color.TextPrimary
		Sounds.Play("Click")
	end

	if data.EloDelta then
		local sign = if data.EloDelta >= 0 then "+" else ""
		detailLabel.Text = ("%s%d Elo"):format(sign, data.EloDelta)
		detailLabel.TextColor3 = if data.EloDelta >= 0 then Theme.Color.Success else Theme.Color.Danger
		applyRankUp(data.EloDelta)
	else
		detailLabel.Text = if data.Total then ("%d of %d racers"):format(data.Placement or 0, data.Total) else ""
		detailLabel.TextColor3 = Theme.Color.TextSecondary
		rankLabel.Text = ""
	end

	Widgets.Open(panel)
	task.wait(3.2)
	Widgets.Close(panel)
	task.wait(0.4)
end

local function processQueue()
	if processing then
		return
	end
	processing = true
	while #queue > 0 do
		show(table.remove(queue, 1))
	end
	processing = false
end

function RaceOutcomeController.Init()
	buildUI()

	local remote = Net.GetRemoteEvent(RemoteNames.RaceOutcome)
	remote.OnClientEvent:Connect(function(data)
		table.insert(queue, data)
		processQueue()
	end)
end

return RaceOutcomeController
