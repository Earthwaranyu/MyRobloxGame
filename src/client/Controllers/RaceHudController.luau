local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

local RaceHudController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local stageLabel: TextLabel
local positionLabel: TextLabel
local timeLabel: TextLabel

-- Set by MapSelected shortly before the race starts (see QueueStatusController
-- for the reveal animation that shows the player the same information).
local currentStageName = ""

local function getStageName(stageId: string): string
	for _, stage in Stages do
		if stage.Id == stageId then
			return stage.Name
		end
	end
	return stageId
end

-- Ticks down locally off the client's own clock, same reasoning as
-- QueueStatusController: server/client os.clock() aren't synced, and this is
-- a display timer only (the authoritative elapsed time is computed
-- server-side in MatchService for leaderboard submission).
local raceStartTime: number? = nil

local function formatTime(seconds: number): string
	local minutes = math.floor(seconds / 60)
	local secs = seconds - minutes * 60
	return ("%d:%05.2f"):format(minutes, secs)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RaceHudGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	panel = Widgets.Panel(UDim2.fromOffset(240, 104), UDim2.new(0.5, -120, 0, 56))
	panel.Parent = screenGui

	stageLabel = Widgets.Label("", UDim2.new(1, -16, 0, 16), UDim2.fromOffset(8, 4), {
		TextSize = 12,
		Color = Theme.Color.TextMuted,
		Align = Enum.TextXAlignment.Center,
	})
	stageLabel.Parent = panel

	positionLabel = Widgets.Label("Position: -", UDim2.new(1, -16, 0, 34), UDim2.fromOffset(8, 20), {
		Font = Theme.Font.Display,
		TextSize = 22,
		Align = Enum.TextXAlignment.Center,
	})
	positionLabel.Parent = panel

	timeLabel = Widgets.Label("0:00.00", UDim2.new(1, -16, 0, 26), UDim2.fromOffset(8, 58), {
		TextSize = 18,
		Color = Theme.Color.TextSecondary,
		Align = Enum.TextXAlignment.Center,
	})
	timeLabel.Parent = panel

	RunService.RenderStepped:Connect(function()
		if not raceStartTime then
			return
		end
		timeLabel.Text = formatTime(os.clock() - raceStartTime)
	end)
end

local function onStateChanged(state: string)
	if state == "Racing" then
		raceStartTime = os.clock()
		timeLabel.Text = "0:00.00"
		positionLabel.Text = "Position: -"
		positionLabel.TextColor3 = Theme.Color.TextPrimary
		stageLabel.Text = currentStageName:upper()
		Widgets.Open(panel)
		-- positionLabel is intentionally left alone: it's set by RacePositionChanged,
		-- a separate remote with no guaranteed ordering relative to this one.
	else
		raceStartTime = nil
		if panel.Visible then
			Widgets.Close(panel)
		end
	end
end

function RaceHudController.Init()
	buildUI()

	MatchStateController.StateChanged:Connect(onStateChanged)
	onStateChanged(MatchStateController.CurrentState)

	local remote = Net.GetRemoteEvent(RemoteNames.RacePositionChanged)
	remote.OnClientEvent:Connect(function(position: number, total: number)
		positionLabel.Text = ("Position: %d/%d"):format(position, total)
		positionLabel.TextColor3 = if position == 1 then Theme.Color.Success else Theme.Color.TextPrimary
	end)

	local mapRemote = Net.GetRemoteEvent(RemoteNames.MapSelected)
	mapRemote.OnClientEvent:Connect(function(stageId: string)
		currentStageName = getStageName(stageId)
	end)
end

return RaceHudController
