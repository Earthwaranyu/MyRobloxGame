local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

local RaceHudController = {}

local player = Players.LocalPlayer

local panel: Frame
local positionLabel: TextLabel
local timeLabel: TextLabel

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

	panel = Widgets.Panel(UDim2.fromOffset(220, 70), UDim2.new(0.5, -110, 0, 60))
	panel.BackgroundTransparency = 0.25
	panel.Parent = screenGui

	positionLabel = Widgets.Label("Position: -", UDim2.new(1, -16, 0, 28), UDim2.fromOffset(8, 4))
	positionLabel.TextXAlignment = Enum.TextXAlignment.Center
	positionLabel.TextSize = 20
	positionLabel.Parent = panel

	timeLabel = Widgets.Label("0:00.00", UDim2.new(1, -16, 0, 28), UDim2.fromOffset(8, 34))
	timeLabel.TextXAlignment = Enum.TextXAlignment.Center
	timeLabel.TextSize = 20
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
		panel.Visible = true
		-- positionLabel is intentionally left alone: it's set by RacePositionChanged,
		-- a separate remote with no guaranteed ordering relative to this one.
	else
		raceStartTime = nil
		panel.Visible = false
	end
end

function RaceHudController.Init()
	buildUI()

	MatchStateController.StateChanged:Connect(onStateChanged)
	onStateChanged(MatchStateController.CurrentState)

	local remote = Net.GetRemoteEvent(RemoteNames.RacePositionChanged)
	remote.OnClientEvent:Connect(function(position: number, total: number)
		positionLabel.Text = ("Position: %d/%d"):format(position, total)
	end)
end

return RaceHudController
