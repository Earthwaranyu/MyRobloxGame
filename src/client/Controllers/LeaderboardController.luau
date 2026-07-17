local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local Widgets = require(script.Parent.Parent.Widgets)

local LeaderboardController = {}

local player = Players.LocalPlayer

local panel: Frame
local entriesList: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}

local selectedStageId = Stages[1].Id

local function formatTime(ms: number): string
	local totalSeconds = ms / 1000
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds - minutes * 60
	return ("%d:%05.2f"):format(minutes, seconds)
end

local function buildEntryRow(entry): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 32)
	row.BackgroundColor3 = if entry.Rank % 2 == 0 then Color3.fromRGB(40, 40, 48) else Color3.fromRGB(48, 48, 56)
	row.BorderSizePixel = 0

	local rankLabel = Widgets.Label(("#%d"):format(entry.Rank), UDim2.new(0, 40, 1, 0), UDim2.fromOffset(8, 0))
	rankLabel.TextSize = 16
	rankLabel.Parent = row

	local nameLabel = Widgets.Label(tostring(entry.Name), UDim2.new(0.5, -48, 1, 0), UDim2.fromOffset(48, 0))
	nameLabel.TextSize = 16
	nameLabel.Parent = row

	local timeLabel = Widgets.Label(formatTime(entry.TimeMs), UDim2.new(0.4, -8, 1, 0), UDim2.fromScale(0.6, 0))
	timeLabel.TextSize = 16
	timeLabel.TextXAlignment = Enum.TextXAlignment.Right
	timeLabel.Parent = row

	return row
end

local function refreshTabHighlight()
	for stageId, button in tabButtons do
		button.BackgroundColor3 = if stageId == selectedStageId
			then Color3.fromRGB(60, 120, 220)
			else Color3.fromRGB(55, 55, 64)
	end
end

function LeaderboardController.Refresh()
	local entries = Net.GetRemoteFunction(RemoteNames.GetLeaderboard):InvokeServer(selectedStageId)

	for _, child in entriesList:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	if #entries == 0 then
		local emptyLabel = Widgets.Label("No times recorded yet.", UDim2.new(1, -16, 0, 32), UDim2.fromOffset(8, 0))
		emptyLabel.Parent = entriesList
		return
	end

	for _, entry in entries do
		local row = buildEntryRow(entry)
		row.LayoutOrder = entry.Rank
		row.Parent = entriesList
	end
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LeaderboardGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- y = 60 clears Roblox's default top bar (chat/leaderboard/settings icons).
	local toggleButton = Widgets.Button("Leaderboard", UDim2.fromOffset(130, 36), UDim2.fromOffset(10, 60))
	toggleButton.Parent = screenGui

	panel = Widgets.Panel(UDim2.fromOffset(360, 420), UDim2.fromOffset(10, 106))
	panel.Parent = screenGui

	local title = Widgets.Label("Leaderboard", UDim2.new(1, -16, 0, 24), UDim2.fromOffset(8, 4))
	title.TextSize = 20
	title.Parent = panel

	local tabRow = Instance.new("Frame")
	tabRow.Size = UDim2.new(1, -16, 0, 30)
	tabRow.Position = UDim2.fromOffset(8, 32)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = panel

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 6)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabRow

	for i, stage in Stages do
		local tabButton = Widgets.Button(stage.Name, UDim2.fromOffset(110, 30), UDim2.fromOffset(0, 0))
		tabButton.Name = "Tab_" .. stage.Id
		tabButton.LayoutOrder = i
		tabButton.Parent = tabRow
		tabButtons[stage.Id] = tabButton

		tabButton.MouseButton1Click:Connect(function()
			selectedStageId = stage.Id
			refreshTabHighlight()
			LeaderboardController.Refresh()
		end)
	end
	refreshTabHighlight()

	entriesList = Instance.new("ScrollingFrame")
	entriesList.Size = UDim2.new(1, -16, 1, -82)
	entriesList.Position = UDim2.fromOffset(8, 74)
	entriesList.BackgroundTransparency = 1
	entriesList.BorderSizePixel = 0
	entriesList.CanvasSize = UDim2.new(0, 0, 0, 0)
	entriesList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	entriesList.ScrollBarThickness = 6
	entriesList.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = entriesList

	toggleButton.MouseButton1Click:Connect(function()
		panel.Visible = not panel.Visible
		if panel.Visible then
			LeaderboardController.Refresh()
		end
	end)
end

function LeaderboardController.Init()
	buildUI()
end

return LeaderboardController
