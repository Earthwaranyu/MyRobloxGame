local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Widgets = require(script.Parent.Parent.Widgets)

local LeaderboardController = {}

-- Hardcoded until a stage picker is built; only Stage1 exists so far.
local STAGE_ID = "Stage1"

local player = Players.LocalPlayer

local panel: Frame
local entriesList: ScrollingFrame

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

function LeaderboardController.Refresh()
	local entries = Net.GetRemoteFunction(RemoteNames.GetLeaderboard):InvokeServer(STAGE_ID)

	for _, child in entriesList:GetChildren() do
		if child:IsA("Frame") then
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

	local title = Widgets.Label("Stage 1 - Top Times", UDim2.new(1, -16, 0, 28), UDim2.fromOffset(8, 4))
	title.TextSize = 20
	title.Parent = panel

	entriesList = Instance.new("ScrollingFrame")
	entriesList.Size = UDim2.new(1, -16, 1, -52)
	entriesList.Position = UDim2.fromOffset(8, 44)
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
