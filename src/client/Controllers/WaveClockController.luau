local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Countdown = require(Shared.Countdown)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
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

-- The tab's own reference geometry lives in Theme.TopLane, not here, because the
-- countdown card below it is positioned against its height -- a tab that grows
-- without the card moving is exactly the overlap that comment used to describe.
-- Responsive.Lane() is those numbers at the current viewport; both controllers
-- read them the same way, so they still agree on every screen.

-- Icon geometry, at reference size. The text is padded by the icon's width plus
-- its inset so the glyph and the words stay optically centred as a pair, which
-- means all three numbers have to scale together or the label drifts off centre.
local ICON_SIZE = 26
local ICON_INSET = 14
local TEXT_INSET = 34
local LABEL_TEXT = 20

-- Below this the tab turns red and pulses once a second. Ten seconds is about
-- how long it takes to notice a banner, cross the plaza and press PLAY, so it's
-- the point where the information stops being ambient and becomes actionable.
local URGENT_SECONDS = 10

local container: Frame
local label: TextLabel
local bevelStrip: Frame?
local scale: UIScale
local departsAt: number? = nil
local lastShownSecond: number? = nil
local urgent = false

-- Gold normally, red in the last few seconds. Recolours the bevel strip along
-- with the face so the tab keeps its 3D edge instead of flattening into a
-- plain red pill the moment it matters most.
local function setUrgent(nowUrgent: boolean)
	if urgent == nowUrgent then
		return
	end
	urgent = nowUrgent
	local palette = if nowUrgent then Theme.Candy.Red else Theme.Candy.Gold
	container.BackgroundColor3 = palette.Face
	if bevelStrip then
		bevelStrip.BackgroundColor3 = palette.Shadow
	end
end

local function refresh()
	if not departsAt then
		label.Text = "NEXT WAVE  --"
		setUrgent(false)
		lastShownSecond = nil
		return
	end

	local remaining = math.max(0, departsAt - os.clock())
	-- Reads "0:42" rather than "42" so it can't be mistaken for the race
	-- countdown, which is a bare number.
	--
	-- Rounded through Shared.Countdown, which is also what QueueStatusController's
	-- card uses -- the two count down to the same instant and used to disagree by
	-- a second because this one floored while that one ceilinged. See that module.
	label.Text = "NEXT WAVE  " .. Countdown.Clock(remaining)
	setUrgent(remaining <= URGENT_SECONDS)

	-- One pop per second, and only while urgent: a banner that bounced every
	-- second for the full minute would be wallpaper by the time it mattered,
	-- and motion in the corner of your eye is the whole mechanism here. Reads
	-- the same rounded second the label shows, so the pop lands ON the tick
	-- rather than a second out of step with the text beside it.
	local shownSecond = Countdown.Seconds(remaining)
	if shownSecond ~= lastShownSecond then
		lastShownSecond = shownSecond
		if urgent then
			scale.Scale = 1.12
			TweenService:Create(scale, Theme.Anim.Pop, { Scale = 1 }):Play()
		end
	end
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

	-- Built as a Widgets.Ribbon rather than a hand-rolled frame so it inherits
	-- the game's candy treatment wholesale -- gold face, thick white border,
	-- darker bevel strip along the bottom edge, outlined GothamBlack text. It's
	-- the same banner used for the world signs and every modal title, so the
	-- tab reads as part of the set instead of a flat HUD chip bolted on top.
	container = Widgets.Ribbon(
		"NEXT WAVE  --",
		UDim2.fromOffset(Theme.TopLane.TabWidth, Theme.TopLane.TabHeight),
		UDim2.new(0.5, 0, 0, Theme.TopLane.TabTop)
	)
	container.Name = "WaveTab"
	container.Parent = screenGui

	label = container:FindFirstChild("Label") :: TextLabel

	-- Nested inside Ribbon's clipping mask. Guarded rather than asserted -- if
	-- Ribbon's internals ever change, the tab should lose its colour-shift, not
	-- throw on startup.
	bevelStrip = container:FindFirstChild("Bevel", true) :: Frame?

	scale = Instance.new("UIScale")
	scale.Parent = container

	-- Clock glyph, drawn from primitives like every other icon in the game
	-- (MenuIcons.Playtime is the existing clock face). Text is nudged right by
	-- the same amount so the pair stays optically centred rather than the words
	-- sitting off-centre next to it.
	local iconHolder = Instance.new("Frame")
	iconHolder.Name = "Icon"
	iconHolder.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
	iconHolder.AnchorPoint = Vector2.new(0, 0.5)
	iconHolder.Position = UDim2.new(0, ICON_INSET, 0.5, 0)
	iconHolder.BackgroundTransparency = 1
	iconHolder.Parent = container
	MenuIcons.Populate(iconHolder, "Playtime", Color3.fromRGB(255, 255, 255))

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, TEXT_INSET)
	padding.Parent = label

	-- The tab is the top item in the lane and everything else in it is placed
	-- below its height, so this has to move with the rest of the lane rather than
	-- staying at its authored 264x44 -- on a phone that width alone is most of
	-- the screen, and the card beneath it would still be positioned as though the
	-- tab were desktop-sized.
	--
	-- Ribbon's own internals are already proportional (label and bevel are both
	-- sized in scale), so only the outer box, the icon and the type need doing.
	local function layout()
		local lane = Responsive.Lane(Theme)
		container.Size = UDim2.fromOffset(lane.TabWidth, lane.TabHeight)
		container.Position = UDim2.new(0.5, 0, 0, lane.TabTop)

		local icon = Responsive.Px(ICON_SIZE)
		iconHolder.Size = UDim2.fromOffset(icon, icon)
		iconHolder.Position = UDim2.new(0, Responsive.Px(ICON_INSET), 0.5, 0)
		padding.PaddingLeft = UDim.new(0, Responsive.Px(TEXT_INSET))
		label.TextSize = Responsive.Text(LABEL_TEXT)
	end
	Responsive.Observe(layout)
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
