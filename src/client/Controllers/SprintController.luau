local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Signal)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

local SprintController = {}

-- Exposed so purely cosmetic client features (wind effect, etc.) can react
-- to sprinting without re-implementing shift-key detection themselves.
SprintController.Sprinting = false
SprintController.SprintingChanged = Signal.new()

local player = Players.LocalPlayer
local sprintIntentRemote: RemoteEvent
local button: TextButton
local buttonHeld = false

local READY_COLOR = Color3.fromRGB(255, 255, 255)
local READY_TEXT_COLOR = Color3.fromRGB(24, 24, 28)

local function updateButtonVisual(isSprinting: boolean)
	if not button then
		return
	end
	if isSprinting then
		button.BackgroundColor3 = Theme.Color.Success
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
	else
		button.BackgroundColor3 = READY_COLOR
		button.TextColor3 = READY_TEXT_COLOR
	end
end

-- Actually setting Humanoid.WalkSpeed used to happen right here on the
-- client. That's a real speedhack vector -- anything a client sets on its
-- own Humanoid replicates as-is, so a hacked client could set WalkSpeed to
-- any number it wants and win every race. This now only tells the server
-- "shift is held or not"; MovementService is the one that actually decides
-- (and enforces) the resulting speed.
local function setSprinting(isSprinting: boolean)
	if SprintController.Sprinting ~= isSprinting then
		SprintController.Sprinting = isSprinting
		SprintController.SprintingChanged:Fire(isSprinting)
		sprintIntentRemote:FireServer(isSprinting)
		updateButtonVisual(isSprinting)
	end
end

local function isSprintKey(keyCode: Enum.KeyCode): boolean
	return keyCode == Enum.KeyCode.LeftShift or keyCode == Enum.KeyCode.RightShift
end

-- Sprint was keyboard-only (Shift) until this button existed -- every other
-- keybind mechanic in this game (dash, emotes, quit match) already has a
-- visible on-screen button that doubles as a touch target, but this one
-- didn't, which meant mobile players had no way to sprint at all. Several
-- stages are tuned assuming sprint is available (see the tutorial copy), so
-- that wasn't just missing polish -- some jumps were likely unbeatable on
-- mobile. Hold-to-sprint via MouseButton1Down/Up, which Roblox also fires
-- for touch taps-and-holds on a GuiButton.
local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SprintGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Sits left of AbilityController's DASH button, mirrored spacing, so the
	-- two read as one small ability bar.
	button = Widgets.Button("SPRINT", UDim2.fromOffset(150, 44), UDim2.new(0.5, -235, 1, -224), {
		Variant = "Secondary",
		TextSize = 16,
	})
	button.Parent = screenGui

	button.MouseButton1Down:Connect(function()
		buttonHeld = true
		setSprinting(true)
	end)
	button.MouseButton1Up:Connect(function()
		buttonHeld = false
		setSprinting(false)
	end)
	-- A touch drag off the button while still holding doesn't reliably fire
	-- MouseButton1Up on Roblox -- without this, a finger sliding off would
	-- leave sprint stuck on with no way to cancel it.
	button.MouseLeave:Connect(function()
		if buttonHeld then
			buttonHeld = false
			setSprinting(false)
		end
	end)
end

function SprintController.Init()
	sprintIntentRemote = Net.GetRemoteEvent(RemoteNames.SetSprintIntent)
	buildUI()

	player.CharacterAdded:Connect(function()
		setSprinting(false)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and isSprintKey(input.KeyCode) then
			setSprinting(true)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if isSprintKey(input.KeyCode) then
			setSprinting(false)
		end
	end)
end

return SprintController
