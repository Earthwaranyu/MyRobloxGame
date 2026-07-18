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

local function buildStreak(parent: Frame, side: string): Frame
	local streak = Instance.new("Frame")
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.Size = UDim2.fromOffset(3 + math.random() * 3, 70 + math.random() * 70)
	streak.BackgroundColor3 = Color3.fromRGB(240, 248, 255)
	streak.BorderSizePixel = 0
	streak.Rotation = math.random() * 20 - 10
	streak.BackgroundTransparency = 1
	local edgeGap = 20 + math.random() * (PANEL_WIDTH - 60)
	local xOffset = if side == "Left" then edgeGap else -edgeGap
	streak.Position = UDim2.new(if side == "Left" then 0 else 1, xOffset, -0.2, 0)
	streak.Parent = parent

	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Rotation = 90
	gradient.Parent = streak

	return streak
end

-- Each streak runs its own top-to-bottom sweep forever, self-gating on
-- `active` at the top of every cycle so it just stops advancing (rather than
-- needing external pause/resume bookkeeping) once the effect switches off.
local function loopStreak(streak: Frame)
	task.spawn(function()
		while true do
			if not active then
				streak.BackgroundTransparency = 1
				task.wait(0.2)
				continue
			end

			local xScale, xOffset = streak.Position.X.Scale, streak.Position.X.Offset
			streak.Position = UDim2.new(xScale, xOffset, -0.2, 0)
			streak.BackgroundTransparency = 0

			local duration = 0.45 + math.random() * 0.35
			local tween = TweenService:Create(streak, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
				Position = UDim2.new(xScale, xOffset, 1.2, 0),
			})
			tween:Play()
			tween.Completed:Wait()
			task.wait(math.random() * 0.35)
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
			loopStreak(buildStreak(panel, side))
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
