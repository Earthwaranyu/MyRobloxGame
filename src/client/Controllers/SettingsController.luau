local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Signal = require(Shared.Signal)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local TutorialController = require(script.Parent.TutorialController)

-- Purely client-side preferences (nothing here needs the server). Other
-- controllers read SettingsController.WindEffectEnabled directly, or listen
-- to Changed for updates -- both are available immediately at require-time,
-- same pattern as MatchStateController/SprintController.
local SettingsController = {}

SettingsController.WindEffectEnabled = true
SettingsController.Changed = Signal.new()

local player = Players.LocalPlayer

local panel: CanvasGroup
local open = false

local function setWindEffect(enabled: boolean, windSetActive: (boolean) -> ())
	SettingsController.WindEffectEnabled = enabled
	windSetActive(enabled)
	SettingsController.Changed:Fire("WindEffect", enabled)
end

-- Cycled rather than dragged: Widgets has no slider component, and a tap
-- target that cycles 100 -> 75 -> 50 -> 25 -> Muted needs nothing new to
-- build while still giving real control. Session-only, same as
-- WindEffectEnabled above -- not saved to the profile.
local VOLUME_LEVELS = { 1, 0.75, 0.5, 0.25, 0 }

local function nextVolumeLevel(current: number): number
	for i, level in VOLUME_LEVELS do
		if math.abs(level - current) < 0.01 then
			return VOLUME_LEVELS[(i % #VOLUME_LEVELS) + 1]
		end
	end
	return VOLUME_LEVELS[1]
end

local function formatVolume(level: number): string
	if level <= 0 then
		return "MUTED"
	end
	return ("%d%%"):format(math.floor(level * 100 + 0.5))
end

-- groupName is the SoundGroup AudioService creates server-side ("Music" or
-- "SFX"); setting its Volume locally only changes what THIS client hears,
-- same as any other client-side property override of a replicated instance.
local function buildVolumeRow(panel: CanvasGroup, labelText: string, yOffset: number, groupName: string)
	local rowLabel = Widgets.Label(labelText, UDim2.new(1, -110, 0, 36), UDim2.fromOffset(8, yOffset), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
	})
	rowLabel.Parent = panel

	local level = 1
	local volumeButton = Widgets.Button(formatVolume(level), UDim2.fromOffset(90, 32), UDim2.new(1, -100, 0, yOffset + 2), {
		Variant = "Tab",
		Active = true,
		TextSize = 14,
	})
	volumeButton.Parent = panel

	volumeButton.MouseButton1Click:Connect(function()
		level = nextVolumeLevel(level)
		volumeButton.Text = formatVolume(level)
		local group = SoundService:WaitForChild(groupName) :: SoundGroup
		group.Volume = level
	end)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SettingsGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- See LeaderboardController for why this is taller than it looks like it
	-- needs to be.
	local toggleButton = Widgets.Button("Settings", UDim2.fromOffset(150, 48), UDim2.new(0, 10, 1, -68))
	toggleButton.Parent = screenGui

	panel = Widgets.Panel(UDim2.fromOffset(320, 234), UDim2.new(0, 10, 1, -310))
	panel.Parent = screenGui

	local title = Widgets.Label("SETTINGS", UDim2.new(1, -16, 0, 26), UDim2.fromOffset(8, 6), {
		TextSize = 20,
	})
	title.Parent = panel

	local rowLabel = Widgets.Label("Wind effect while sprinting", UDim2.new(1, -110, 0, 44), UDim2.fromOffset(8, 44), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
	})
	rowLabel.Parent = panel

	local windButton, windSetActive = Widgets.Button("ON", UDim2.fromOffset(90, 36), UDim2.new(1, -100, 0, 44), {
		Variant = "Tab",
		Active = true,
	})
	windButton.Parent = panel
	windSetActive(true)

	windButton.MouseButton1Click:Connect(function()
		local enabled = not SettingsController.WindEffectEnabled
		windButton.Text = if enabled then "ON" else "OFF"
		setWindEffect(enabled, windSetActive)
	end)

	buildVolumeRow(panel, "Music volume", 92, "Music")
	buildVolumeRow(panel, "SFX volume", 136, "SFX")

	local howToPlayButton = Widgets.Button("How to Play", UDim2.new(1, -16, 0, 40), UDim2.fromOffset(8, 184), {
		Variant = "Secondary",
		TextSize = 16,
	})
	howToPlayButton.Parent = panel
	howToPlayButton.MouseButton1Click:Connect(function()
		TutorialController.Show()
	end)

	toggleButton.MouseButton1Click:Connect(function()
		open = not open
		if open then
			Widgets.Open(panel)
		else
			Widgets.Close(panel)
		end
	end)
end

function SettingsController.Init()
	buildUI()
end

return SettingsController
