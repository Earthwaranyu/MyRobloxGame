local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local SprintController = require(script.Parent.SprintController)
local SettingsController = require(script.Parent.SettingsController)
local MatchStateController = require(script.Parent.MatchStateController)

-- Racing is first-person (see CameraController), so a world-space trail
-- behind the character (the first version of this) is literally never seen
-- by the person it's for. This is a screen-space effect instead: streaks
-- rushing past the left/right edges of the view, like a runner game's speed
-- lines, only while actually racing + sprinting + enabled in Settings.
local WindEffectController = {}

local player = Players.LocalPlayer

-- Plasma Trails Constant Airy Whooshing Windy (SFX), Pro Sound Effects --
-- same verified-free asset already used for Stage2's Stormy weather bed.
local WIND_SOUND_ID = "rbxassetid://9125742262"
local WIND_VOLUME = 0.3
local FADE_TIME = 0.4
local STREAKS_PER_SIDE = 6
local PANEL_WIDTH = 220

local windSound = Instance.new("Sound")
windSound.Name = "SprintWindSound"
windSound.SoundId = WIND_SOUND_ID
windSound.Looped = true
windSound.Volume = 0
windSound.Parent = SoundService

local active = false
local panels: { Frame } = {}

-- Faint edge-of-vision tint, brightest right at the screen edge and fading
-- toward the center -- the "air pressure" backdrop the streaks fly across.
local function buildVignette(side: string): Frame
	local panel = Instance.new("Frame")
	panel.Name = side .. "WindPanel"
	panel.Size = UDim2.new(0, PANEL_WIDTH, 1, 0)
	panel.Position = if side == "Left" then UDim2.fromScale(0, 0) else UDim2.new(1, -PANEL_WIDTH, 0, 0)
	panel.BackgroundColor3 = Color3.fromRGB(225, 240, 255)
	panel.BackgroundTransparency = 0.72
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.Visible = false

	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, if side == "Left" then 0 else 1),
		NumberSequenceKeypoint.new(1, if side == "Left" then 1 else 0),
	})
	gradient.Parent = panel

	return panel
end

local BASE_STREAK_HEIGHT = 90

local function buildStreak(parent: Frame): Frame
	local streak = Instance.new("Frame")
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.Size = UDim2.fromOffset(4, BASE_STREAK_HEIGHT)
	streak.BackgroundColor3 = Color3.fromRGB(240, 248, 255)
	streak.BorderSizePixel = 0
	streak.BackgroundTransparency = 1
	streak.Parent = parent

	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Rotation = 90
	gradient.Parent = streak

	return streak
end

-- Wind hitting a face doesn't fall straight down like rain -- it splits and
-- curls back past you. Each pass starts near the inner edge of the panel (as
-- if right in front of your face) at a random "eye level" height, then
-- sweeps out toward the true screen edge across two legs while drifting
-- further up or down and rotating from near-vertical to swept-back, tracing
-- an arc instead of a straight line.
local function animateStreak(streak: Frame, side: string)
	local sign = if side == "Left" then 1 else -1
	local anchorScale = if side == "Left" then 0 else 1

	local curveDir = if math.random() < 0.5 then 1 else -1
	local startY = math.random(-120, 120)
	local midY = startY + curveDir * (35 + math.random() * 45)
	local endY = startY + curveDir * (100 + math.random() * 80)

	local startInset = PANEL_WIDTH * (0.55 + math.random() * 0.3)
	local midInset = PANEL_WIDTH * (0.15 + math.random() * 0.2)
	local endInset = -(10 + math.random() * 30)

	local startRotation = sign * (4 + math.random() * 6)
	local midRotation = sign * (30 + math.random() * 14)
	local endRotation = sign * (58 + math.random() * 18)

	streak.Rotation = startRotation
	streak.Size = UDim2.fromOffset(4, BASE_STREAK_HEIGHT * (0.8 + math.random() * 0.4))
	streak.Position = UDim2.new(anchorScale, sign * startInset, 0.5, startY)
	streak.BackgroundTransparency = 1

	TweenService:Create(streak, TweenInfo.new(0.08), { BackgroundTransparency = 0 }):Play()

	local leg1 = TweenService:Create(
		streak,
		TweenInfo.new(0.16 + math.random() * 0.06, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Position = UDim2.new(anchorScale, sign * midInset, 0.5, midY), Rotation = midRotation }
	)
	leg1:Play()
	leg1.Completed:Wait()

	local leg2 = TweenService:Create(
		streak,
		TweenInfo.new(0.22 + math.random() * 0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{
			Position = UDim2.new(anchorScale, sign * endInset, 0.5, endY),
			Rotation = endRotation,
			BackgroundTransparency = 1,
		}
	)
	leg2:Play()
	leg2.Completed:Wait()
end

-- Each streak runs its own curved pass forever, self-gating on `active` at
-- the top of every cycle so it just stops advancing (rather than needing
-- external pause/resume bookkeeping) once the effect switches off.
local function loopStreak(streak: Frame, side: string)
	task.spawn(function()
		while true do
			if not active then
				streak.BackgroundTransparency = 1
				task.wait(0.2)
				continue
			end

			animateStreak(streak, side)
			task.wait(math.random() * 0.3)
		end
	end)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "WindEffectGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 2
	screenGui.Parent = player:WaitForChild("PlayerGui")

	for _, side in { "Left", "Right" } do
		local panel = buildVignette(side)
		panel.Parent = screenGui
		table.insert(panels, panel)
		for _ = 1, STREAKS_PER_SIDE do
			loopStreak(buildStreak(panel), side)
		end
	end
end

local function refresh()
	local shouldShow = SprintController.Sprinting
		and SettingsController.WindEffectEnabled
		and MatchStateController.CurrentState == "Racing"
	if shouldShow == active then
		return
	end
	active = shouldShow

	for _, panel in panels do
		panel.Visible = active
	end

	if active then
		if not windSound.IsPlaying then
			windSound:Play()
		end
		TweenService:Create(windSound, TweenInfo.new(FADE_TIME), { Volume = WIND_VOLUME }):Play()
	else
		TweenService:Create(windSound, TweenInfo.new(FADE_TIME), { Volume = 0 }):Play()
		task.delay(FADE_TIME, function()
			if not active then
				windSound:Stop()
			end
		end)
	end
end

function WindEffectController.Init()
	buildUI()

	SprintController.SprintingChanged:Connect(refresh)
	SettingsController.Changed:Connect(refresh)
	MatchStateController.StateChanged:Connect(refresh)
end

return WindEffectController
