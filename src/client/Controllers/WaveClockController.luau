local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local MatchStateController = require(script.Parent.MatchStateController)

-- A small tab at the top of the screen counting down to the next PLAY wave.
--
-- Shown to EVERYONE in the lobby, not just people who have queued: waves leave
-- on a fixed clock, and the whole benefit of a fixed clock is that you can see
-- it and decide whether to make this one. Without it the cadence is invisible
-- to anyone who hasn't already pressed PLAY, which is exactly the group it
-- should be pulling in.
--
-- The server sends the remaining seconds once per wave and this ticks down
-- locally, rather than streaming a value every second -- same approach as
-- QueueStatusController, and for the same reason: it avoids depending on the
-- client and server clocks agreeing.
local WaveClockController = {}

local player = Players.LocalPlayer

local TAB_WIDTH = 250
local TAB_HEIGHT = 32
-- Above everything else in the top-centre lane. The queue card sits at y=60 and
-- RaceHudController's timer at y=56 (never both at once), so 6..38 is clear of
-- each -- and of the Roblox topbar, since the ScreenGui keeps the default inset.
local TAB_TOP = 6

local container: Frame
local label: TextLabel
local departsAt: number? = nil

local function refresh()
	if not departsAt then
		label.Text = "NEXT WAVE  --"
		return
	end
	local remaining = math.max(0, departsAt - os.clock())
	-- Reads "0:42" rather than "42" so it can't be mistaken for the race
	-- countdown, which is a bare number.
	label.Text = ("NEXT WAVE  %d:%02d"):format(math.floor(remaining / 60), math.floor(remaining % 60))
end

-- Hidden while racing. A slow racer can't act on it -- they're mid-course and
-- can't join the next wave anyway -- so it would be pure clutter on the one
-- screen where clutter costs you a jump. Same reasoning as the hype feed.
local function updateVisibility()
	container.Visible = MatchStateController.CurrentState ~= "Racing"
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "WaveClockGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 3
	screenGui.Parent = player:WaitForChild("PlayerGui")

	container = Instance.new("Frame")
	container.Name = "WaveTab"
	container.Size = UDim2.fromOffset(TAB_WIDTH, TAB_HEIGHT)
	container.Position = UDim2.new(0.5, -TAB_WIDTH / 2, 0, TAB_TOP)
	container.BackgroundColor3 = Color3.fromRGB(26, 27, 38)
	container.BackgroundTransparency = 0.1
	container.BorderSizePixel = 0
	container.Parent = screenGui

	-- Rounded on the bottom corners only would be ideal (it reads as a tab
	-- hanging from the top edge), but UICorner is all-or-nothing, so a fully
	-- rounded pill it is -- consistent with the rest of the HUD anyway.
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Candy.Border
	stroke.Thickness = 2
	stroke.Transparency = 0.35
	stroke.Parent = container

	label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "NEXT WAVE  --"
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Theme.Font.Display
	label.TextSize = 17
	label.Parent = container
end

function WaveClockController.Init()
	buildUI()
	updateVisibility()

	Net.GetRemoteEvent(RemoteNames.WaveClock).OnClientEvent:Connect(function(secondsRemaining: number?)
		departsAt = if secondsRemaining then os.clock() + secondsRemaining else nil
		refresh()
	end)

	MatchStateController.StateChanged:Connect(updateVisibility)

	RunService.Heartbeat:Connect(refresh)
end

return WaveClockController
