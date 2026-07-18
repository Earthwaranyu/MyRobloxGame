local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- The one universal ability (see Constants.Ability for why it's free/equal
-- for everyone, not a pickup or Robux perk). Q is the real interaction --
-- same first-person mouse-lock reasoning as QuitMatchController/
-- EmoteController -- the button is a visible reminder of the key and a
-- cooldown readout, and still works on the rare occasion the cursor is free.
-- The actual dash physics (BodyVelocity, direction, cooldown enforcement)
-- all live server-side in AbilityService; this only ever sends "dash now".
local DASH_KEY = Enum.KeyCode.Q
local DASH_COOLDOWN = Constants.Ability.DashCooldownSeconds

local AbilityController = {}

local player = Players.LocalPlayer

local button: TextButton
local dashRemote: RemoteEvent
local flashFrame: Frame
local readyAt = 0

local READY_COLOR = Color3.fromRGB(255, 255, 255)
local READY_TEXT_COLOR = Color3.fromRGB(24, 24, 28)

local function updateButton()
	local remaining = readyAt - os.clock()
	if remaining > 0 then
		button.Text = ("DASH  %.1fs"):format(remaining)
		button.BackgroundColor3 = Theme.Color.PanelLight
		button.TextColor3 = Theme.Color.TextMuted
	else
		button.Text = "DASH (Q)"
		button.BackgroundColor3 = READY_COLOR
		button.TextColor3 = READY_TEXT_COLOR
	end
end

-- Quick full-screen color flash, purely a client-side "that just happened"
-- cue -- deliberately not touching camera.FieldOfView, since RunBobController
-- already drives that continuously while sprinting and a second controller
-- fighting it over the same property would just cause jitter.
local function playFlash()
	flashFrame.BackgroundTransparency = 0.82
	TweenService:Create(flashFrame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
end

local function tryDash()
	if os.clock() < readyAt then
		return
	end
	readyAt = os.clock() + DASH_COOLDOWN
	updateButton()
	playFlash()
	dashRemote:FireServer()

	task.spawn(function()
		while os.clock() < readyAt do
			updateButton()
			task.wait(0.1)
		end
		updateButton()
	end)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AbilityGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Sits directly above the VS BOTS button (see PlayButtonController), same
	-- 8px-gap convention used throughout this stack of bottom-center buttons.
	button = Widgets.Button("DASH (Q)", UDim2.fromOffset(150, 44), UDim2.new(0.5, -75, 1, -224), {
		Variant = "Secondary",
		TextSize = 16,
	})
	button.Parent = screenGui
	button.MouseButton1Click:Connect(tryDash)

	local flashGui = Instance.new("ScreenGui")
	flashGui.Name = "DashFlashGui"
	flashGui.ResetOnSpawn = false
	flashGui.IgnoreGuiInset = true
	flashGui.DisplayOrder = 15
	flashGui.Parent = player:WaitForChild("PlayerGui")

	flashFrame = Instance.new("Frame")
	flashFrame.Size = UDim2.fromScale(1, 1)
	flashFrame.BackgroundColor3 = Color3.fromRGB(140, 200, 255)
	flashFrame.BackgroundTransparency = 1
	flashFrame.BorderSizePixel = 0
	flashFrame.Active = false -- must not block clicks to anything underneath
	flashFrame.Parent = flashGui
end

function AbilityController.Init()
	buildUI()
	dashRemote = Net.GetRemoteEvent(RemoteNames.RequestDash)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.KeyCode ~= DASH_KEY then
			return
		end
		tryDash()
	end)

	-- Mirrors AbilityService.ResetDashCooldown, which the server calls at the
	-- exact same "Racing" transition -- keeps the UI honest instead of
	-- showing a stale countdown left over from dashing during the free
	-- pre-race warmup.
	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Racing" then
			readyAt = 0
			updateButton()
		end
	end)
end

return AbilityController
