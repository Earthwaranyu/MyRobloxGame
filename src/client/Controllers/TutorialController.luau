local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- Shown once automatically (server tells us via ShowTutorial the very first
-- time a fresh profile logs in) and re-openable anytime after that from
-- Settings -> "How to Play". Everything on this panel is otherwise only
-- discoverable by trial and error (sprint key, emote keys, quit key) -- a
-- brand-new player with zero explanation is exactly who churns in the first
-- 30 seconds.
local TutorialController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup

local ROWS = {
	{ Icon = "🏁", Title = "Race to win", Body = "Tap PLAY to race real players, or VS BOTS to practice solo." },
	{ Icon = "🏃", Title = "Hold SHIFT to sprint", Body = "You'll need it to clear the harder jumps." },
	{ Icon = "💨", Title = "Press Q to dash", Body = "A short burst of speed on a cooldown -- save it for a tricky jump." },
	{ Icon = "🏆", Title = "Elo & Points", Body = "Win real races for Elo and rank up. Points buy trails in the Shop." },
	{ Icon = "😀", Title = "Emotes", Body = "Press 1-8 anytime to show one off, even mid-race." },
	{ Icon = "🚪", Title = "Need to bail?", Body = "Press Backspace anytime to leave a match." },
}

local function buildRow(container: Frame, row, layoutOrder: number)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 56)
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = layoutOrder
	frame.Parent = container

	local icon = Widgets.Label(row.Icon, UDim2.fromOffset(40, 40), UDim2.fromOffset(0, 8), {
		TextSize = 26,
		Align = Enum.TextXAlignment.Center,
	})
	icon.Parent = frame

	local title = Widgets.Label(row.Title, UDim2.new(1, -52, 0, 22), UDim2.fromOffset(52, 2), {
		Font = Theme.Font.Heading,
		TextSize = 17,
	})
	title.Parent = frame

	local body = Widgets.Label(row.Body, UDim2.new(1, -52, 0, 28), UDim2.fromOffset(52, 24), {
		TextSize = 14,
		Color = Theme.Color.TextSecondary,
	})
	body.Parent = frame

	return frame
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "TutorialGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 20
	screenGui.Parent = player:WaitForChild("PlayerGui")

	panel = Widgets.Panel(UDim2.fromOffset(480, 528), UDim2.new(0.5, -240, 0.5, -264))
	panel.Parent = screenGui

	local title = Widgets.Label("WELCOME TO THE RACE!", UDim2.new(1, -32, 0, 32), UDim2.fromOffset(16, 16), {
		Font = Theme.Font.Display,
		TextSize = 24,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.Warning,
	})
	title.Parent = panel

	local rowsContainer = Instance.new("Frame")
	rowsContainer.Size = UDim2.new(1, -32, 0, 360)
	rowsContainer.Position = UDim2.fromOffset(16, 56)
	rowsContainer.BackgroundTransparency = 1
	rowsContainer.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = rowsContainer

	for i, row in ROWS do
		buildRow(rowsContainer, row, i)
	end

	local closeButton = Widgets.Button("GOT IT, LET'S GO!", UDim2.fromOffset(260, 52), UDim2.new(0.5, -130, 1, -68), {
		Variant = "Success",
		TextSize = 18,
	})
	closeButton.Parent = panel
	closeButton.MouseButton1Click:Connect(function()
		Widgets.Close(panel)
	end)
end

function TutorialController.Show()
	Sounds.Play("Purchase")
	Widgets.Open(panel)
end

function TutorialController.Init()
	buildUI()

	local remote = Net.GetRemoteEvent(RemoteNames.ShowTutorial)
	remote.OnClientEvent:Connect(TutorialController.Show)
end

return TutorialController
