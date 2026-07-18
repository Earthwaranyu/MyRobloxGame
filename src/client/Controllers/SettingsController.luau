local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Signal = require(Shared.Signal)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

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

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SettingsGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- See LeaderboardController for why this is taller than it looks like it
	-- needs to be.
	local toggleButton = Widgets.Button("Settings", UDim2.fromOffset(150, 48), UDim2.new(0, 10, 1, -68))
	toggleButton.Parent = screenGui

	panel = Widgets.Panel(UDim2.fromOffset(320, 140), UDim2.new(0, 10, 1, -216))
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
