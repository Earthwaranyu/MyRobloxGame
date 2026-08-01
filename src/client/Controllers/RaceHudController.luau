local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

local RaceHudController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local stageLabel: TextLabel
local positionLabel: TextLabel
local timeLabel: TextLabel

-- Reference geometry. This panel is the third member of Theme's top-centre lane
-- (the race timer), and the only one that never actually read the lane's numbers
-- -- its 240x104 at y=56 is hand-placed and does not line up with the lane's own
-- CardTop of 82. Left alone that is a cosmetic 26px, but once the lane scales
-- with the viewport and this does not, the gap becomes a real overlap on small
-- screens. So it scales too, against its own authored numbers rather than being
-- silently re-homed onto the lane -- moving it is a visual decision, and this
-- change is about making the HUD survive a phone, not about re-siting the timer.
local PANEL_WIDTH = 240
local PANEL_HEIGHT = 104
local PANEL_TOP = 56
local PANEL_PAD = 8
local STAGE_HEIGHT, STAGE_TOP, STAGE_TEXT = 16, 4, 12
local POSITION_HEIGHT, POSITION_TOP, POSITION_TEXT = 34, 20, 22
local TIME_HEIGHT, TIME_TOP, TIME_TEXT = 26, 58, 18

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

	panel = Widgets.Panel(UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT), UDim2.new(0.5, -PANEL_WIDTH / 2, 0, PANEL_TOP))
	panel.Parent = screenGui

	stageLabel =
		Widgets.Label("", UDim2.new(1, -PANEL_PAD * 2, 0, STAGE_HEIGHT), UDim2.fromOffset(PANEL_PAD, STAGE_TOP), {
			TextSize = STAGE_TEXT,
			Color = Theme.Color.TextMuted,
			Align = Enum.TextXAlignment.Center,
		})
	stageLabel.Parent = panel

	positionLabel = Widgets.Label(
		"Position: -",
		UDim2.new(1, -PANEL_PAD * 2, 0, POSITION_HEIGHT),
		UDim2.fromOffset(PANEL_PAD, POSITION_TOP),
		{
			Font = Theme.Font.Display,
			TextSize = POSITION_TEXT,
			Align = Enum.TextXAlignment.Center,
		}
	)
	positionLabel.Parent = panel

	timeLabel =
		Widgets.Label("0:00.00", UDim2.new(1, -PANEL_PAD * 2, 0, TIME_HEIGHT), UDim2.fromOffset(PANEL_PAD, TIME_TOP), {
			TextSize = TIME_TEXT,
			Color = Theme.Color.TextSecondary,
			Align = Enum.TextXAlignment.Center,
		})
	timeLabel.Parent = panel

	local function layout()
		local width = Responsive.Px(PANEL_WIDTH)
		local pad = Responsive.Px(PANEL_PAD)
		panel.Size = UDim2.fromOffset(width, Responsive.Px(PANEL_HEIGHT))
		panel.Position = UDim2.new(0.5, -width / 2, 0, Responsive.Px(PANEL_TOP))

		local rows = {
			{ Label = stageLabel, Height = STAGE_HEIGHT, Top = STAGE_TOP, Text = STAGE_TEXT },
			{ Label = positionLabel, Height = POSITION_HEIGHT, Top = POSITION_TOP, Text = POSITION_TEXT },
			{ Label = timeLabel, Height = TIME_HEIGHT, Top = TIME_TOP, Text = TIME_TEXT },
		}
		for _, row in rows do
			row.Label.Size = UDim2.new(1, -pad * 2, 0, Responsive.Px(row.Height))
			row.Label.Position = UDim2.fromOffset(pad, Responsive.Px(row.Top))
			row.Label.TextSize = Responsive.Text(row.Text)
		end
	end
	Responsive.Observe(layout)

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
