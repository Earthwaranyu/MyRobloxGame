local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local RankTiers = require(Shared.RankTiers)

local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- Server sends up to two RaceOutcome events per race: one economic (Won +
-- EloDelta) fired the instant a winner is decided, and one placement-only
-- event fired when this player personally crosses the line. See
-- MatchService.PlayerReachedFinish for the exact rules.
local RaceOutcomeController = {}

local OUTCOME_WIDTH, OUTCOME_HEIGHT = 380, 196

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
	panel = Widgets.Panel(UDim2.fromOffset(OUTCOME_WIDTH, OUTCOME_HEIGHT), UDim2.new(0.5, -OUTCOME_WIDTH / 2, 0.55, 0))
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

	-- y = 0.55 was chosen to clear the countdown/"GO!" flash near y = 0.22-0.3.
	-- On a 375pt phone that resolves to y = 206, and 206 + 196 = 402 -- so the
	-- bottom 27pt of your own race result sat off the screen. Kept at 0.55 where
	-- there is room and clamped up where there isn't, so it still avoids the
	-- flash on the screens that can fit both.
	--
	-- The PANEL was made responsive; its four rows were not, and they were the
	-- part that had to be. Their y offsets are authored against the full 196pt
	-- card, so on any viewport where PlacePanel scales the card down -- 141pt on a
	-- 706x579 tablet -- the streak line still sat at y 136..160 and hung 19pt
	-- below the bottom of the card it belongs to. A CanvasGroup does not clip
	-- that, so it rendered as a loose line of gold text floating under the panel.
	Responsive.Observe(function()
		local px, tx = Responsive.Px, Responsive.Text
		local viewport = Responsive.ViewportSize()
		local width = math.min(px(OUTCOME_WIDTH), viewport.X - Responsive.ScreenMargin * 2)
		Responsive.PlacePanel(
			panel,
			OUTCOME_WIDTH,
			OUTCOME_HEIGHT,
			math.round((viewport.X - width) / 2),
			math.round(viewport.Y * 0.55)
		)

		local pad = px(10)
		local function place(label: TextLabel, y: number, height: number, size: number)
			label.Size = UDim2.new(1, -pad * 2, 0, px(height))
			label.Position = UDim2.fromOffset(pad, px(y))
			label.TextSize = tx(size)
		end
		place(titleLabel, 16, 50, 34)
		place(detailLabel, 70, 28, 20)
		place(rankLabel, 106, 24, 16)
		place(streakLabel, 136, 24, 17)
	end)
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

local function show(data: {
	Won: boolean,
	EloDelta: number?,
	Placement: number?,
	Total: number?,
	WinStreak: number?,
	StreakBonus: number?,
	Points: number?,
})
	streakLabel.Text = ""
	if data.Won then
		titleLabel.Text = "VICTORY!"
		titleLabel.TextColor3 = Theme.Color.Warning
		Sounds.Play("Victory")

		if data.WinStreak and data.WinStreak >= 2 then
			local bonusText = if data.StreakBonus and data.StreakBonus > 0
				then (" (+%d pts)"):format(data.StreakBonus)
				else ""
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

	-- Elo and points are both rewards for the same race, so they share one
	-- line rather than competing for the panel. Points were previously never
	-- shown at all on ANY path -- a bot win silently added them, and even a
	-- ranked win only ever advertised its Elo -- so the currency the shop and
	-- gacha both run on was invisible at the exact moment it was earned.
	local parts: { string } = {}
	if data.EloDelta then
		local sign = if data.EloDelta >= 0 then "+" else ""
		table.insert(parts, ("%s%d Elo"):format(sign, data.EloDelta))
	end
	if data.Points and data.Points > 0 then
		table.insert(parts, ("+%d pts"):format(data.Points))
	end

	if #parts > 0 then
		detailLabel.Text = table.concat(parts, "   ")
		-- Only a genuine Elo loss should read as bad news; points are always
		-- a gain, so a points-only line (bot matches) stays positive.
		detailLabel.TextColor3 = if data.EloDelta and data.EloDelta < 0 then Theme.Color.Danger else Theme.Color.Success
	else
		detailLabel.Text = if data.Total then ("%d of %d racers"):format(data.Placement or 0, data.Total) else ""
		detailLabel.TextColor3 = Theme.Color.TextSecondary
	end

	if data.EloDelta then
		applyRankUp(data.EloDelta)
	else
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
